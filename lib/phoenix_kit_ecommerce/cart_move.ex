defmodule PhoenixKitEcommerce.CartMove do
  @moduledoc false
  # The line-moving core behind `PhoenixKitEcommerce.move_cart_lines/3`, shared
  # by the checkout claim's "add" merge (`API.Claims`) and the cross-domain
  # handoff (`PhoenixKitEcommerce.handoff_apply/2`).
  #
  # Every line of the source goes into the target through `add_to_cart/4`, so
  # it is re-read, re-validated and priced at the TARGET cart's currency and
  # the product's current price. A line is validated here first, because a
  # refusal made inside `add_to_cart`'s own transaction would doom the
  # surrounding one.

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartOptions
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.Cart

  @preloads [:items, :shipping_method]

  def move(%Cart{uuid: uuid}, %Cart{uuid: uuid}, _opts), do: {:error, :same_cart}

  def move(%Cart{} = source, %Cart{} = target, opts) do
    case repo().transaction(fn -> move_locked!(source, target, opts) end) do
      {:ok, {moved_into, report}} -> {:ok, moved_into, report}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      if CartWriter.deadlock?(error), do: {:error, :busy}, else: reraise(error, __STACKTRACE__)
  end

  defp move_locked!(source, target, opts) do
    lock_identities!(source, target)
    {source, target} = lock_rows!(source.uuid, target.uuid)

    cond do
      # The call made before: its lines are in the target, the source is done.
      source.status == "merged" and source.merged_into_cart_uuid == target.uuid ->
        {target, %{moved: 0, skipped: []}}

      source.status != "active" or target.status != "active" ->
        repo().rollback(:cart_not_active)

      true ->
        move_lines!(source, target, opts)
    end
  end

  # One order for every caller: the user keys sorted, then the session keys
  # sorted, so two moves over the same carts (in whatever roles) cannot take
  # them crosswise. Both are re-entrant for the transaction that holds them
  # already, which is the claim's case.
  defp lock_identities!(source, target) do
    carts = [source, target]

    for user_uuid <- identity_values(carts, :user_uuid),
        do: Shop.lock_cart_identity!(user_uuid, nil)

    for session_id <- identity_values(carts, :session_id),
        do: Shop.lock_cart_identity!(nil, session_id)

    :ok
  end

  defp identity_values(carts, field) do
    carts
    |> Enum.map(&Map.fetch!(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Both rows in one statement, in uuid order, with their lines read after the
  # lock: the caller's structs may be many events old.
  defp lock_rows!(source_uuid, target_uuid) do
    carts =
      from(c in Cart,
        where: c.uuid in ^[source_uuid, target_uuid],
        order_by: c.uuid,
        lock: "FOR UPDATE"
      )
      |> repo().all()
      |> repo().preload(@preloads, force: true)

    with %Cart{} = source <- Enum.find(carts, &(&1.uuid == source_uuid)),
         %Cart{} = target <- Enum.find(carts, &(&1.uuid == target_uuid)) do
      {source, target}
    else
      _gone -> repo().rollback(:cart_not_found)
    end
  end

  defp move_lines!(source, target, opts) do
    language = Keyword.get(opts, :language)
    via = Keyword.get(opts, :via)
    records = load_records(source.items, language)

    # Product-uuid order, like the writer: two moves (or a move and a write)
    # that share two products must not lock their rows crosswise.
    {moved_into, moved, skipped} =
      source.items
      |> Enum.sort_by(&(CartView.line_product_id(&1) || ""))
      |> Enum.reduce({target, 0, []}, fn item, {cart, moved, skipped} ->
        case add_line(cart, item, records, language, via) do
          {:ok, updated} -> {updated, moved + 1, skipped}
          {:skipped, reason} -> {cart, moved, [skipped_line(item, reason) | skipped]}
        end
      end)

    source
    |> Cart.status_changeset("merged", %{merged_into_cart_uuid: moved_into.uuid})
    |> repo().update!()

    {moved_into, %{moved: moved, skipped: Enum.reverse(skipped)}}
  end

  # One loader call for every product of the source: the records carry the
  # visibility state of the public API, the one rule of what may be carted.
  defp load_records(items, language) do
    Loader.load(
      Enum.map(items, &CartView.line_product_id/1),
      if(language, do: [language: language], else: [])
    )
  end

  defp skipped_line(item, reason),
    do: %{product_uuid: CartView.line_product_id(item), name: item.product_title, reason: reason}

  defp add_line(cart, item, records, language, via) do
    with product_id when is_binary(product_id) <- CartView.line_product_id(item),
         {:ok, product} <- listed_product(records, product_id),
         {:ok, specs} <- specs_for(product, item),
         quantity when quantity > 0 <- room_for(cart, product, specs, item.quantity) do
      add_checked(cart, product, quantity, specs, language, via)
    else
      nil -> {:skipped, :not_found}
      {:error, reason} when reason in [:not_found, :not_on_sale] -> {:skipped, reason}
      :error -> {:skipped, :invalid_options}
      # The line the target already holds at the cap (`room_for/4` is 0): named,
      # not dropped quietly.
      0 -> {:skipped, :quantity_cap}
    end
  end

  # Only a refusal that `add_to_cart` makes before it writes anything skips the
  # line. Any other answer means the product changed since the check above and
  # the surrounding transaction may be doomed: nothing is moved, the caller
  # tries again.
  defp add_checked(cart, product, quantity, specs, language, via) do
    opts = [selected_specs: specs, language: language, via: via]

    case Shop.add_to_cart(cart, product, quantity, opts) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, {:insufficient_stock, _lines}} ->
        {:skipped, :insufficient_stock}

      {:error, reason} when is_atom(reason) ->
        if CartWriter.refused_before_write?(reason),
          do: {:skipped, reason},
          else: repo().rollback(:busy)

      _other ->
        repo().rollback(:busy)
    end
  end

  defp listed_product(records, product_id) do
    with id when is_binary(id) <- Loader.canonical_uuid(product_id) do
      CartWriter.addable_product(Map.get(records, id))
    end
  end

  defp specs_for(product, item) do
    case CartOptions.to_specs(product, CartOptions.from_item(item, product)) do
      {:ok, specs} ->
        {:ok, specs}

      {:error, _code, _context} ->
        specs = item.selected_specs || %{}
        if Shop.validate_selected_specs(product, specs) == :ok, do: {:ok, specs}, else: :error
    end
  end

  defp room_for(cart, product, specs, wanted) do
    existing =
      Enum.find(cart.items, fn line ->
        CartView.line_product_id(line) == product.uuid and (line.selected_specs || %{}) == specs
      end)

    max(0, min(wanted, CartWriter.max_quantity() - ((existing && existing.quantity) || 0)))
  end

  defp repo, do: RepoHelper.repo()
end
