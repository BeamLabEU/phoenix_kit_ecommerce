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
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Events

  @preloads [:items, :shipping_method]

  def move(%Cart{uuid: uuid}, %Cart{uuid: uuid}, _opts), do: {:error, :same_cart}

  def move(%Cart{} = source, %Cart{} = target, opts) do
    # With a transaction of its own the move knows when it commits, so the lines
    # are not announced one by one as they go in: each cart is announced once
    # afterwards. Inside the caller's transaction it cannot know, and leaves
    # `add_to_cart/4` to announce the lines as it always has (the claim).
    announce_after_commit? = not repo().in_transaction?()

    case repo().transaction(fn -> move_locked!(source, target, opts, announce_after_commit?) end) do
      {:ok, {moved_into, report, source_after, changed?}} ->
        if announce_after_commit? and changed?, do: announce(moved_into, source_after)
        {:ok, moved_into, report}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      if CartWriter.deadlock?(error), do: {:error, :busy}, else: reraise(error, __STACKTRACE__)
  end

  defp announce(target, source) do
    Events.broadcast_cart_updated(target)
    Events.broadcast_cart_updated(source)
  end

  defp move_locked!(source, target, opts, announce_after_commit?) do
    lock_identities!(source, target)
    {source, target} = lock_rows!(source.uuid, target.uuid)

    cond do
      # The call made before: its lines are in the target, the source is done.
      source.status == "merged" and source.merged_into_cart_uuid == target.uuid ->
        {target, %{moved: 0, skipped: []}, source, false}

      source.status != "active" or target.status != "active" ->
        repo().rollback(:cart_not_active)

      true ->
        case source_refusal(source, opts) do
          nil -> move_lines!(source, target, opts, announce_after_commit?)
          reason -> repo().rollback(reason)
        end
    end
  end

  # What the locked source may not be moved for, when the caller asked for it
  # to be a guest cart (`guest_source: true`): the caller's own read of the
  # cart may be many events old, and the lock is where it is judged.
  defp source_refusal(%Cart{} = source, opts) do
    if Keyword.get(opts, :guest_source, false), do: guest_refusal(source)
  end

  defp guest_refusal(%Cart{user_uuid: user_uuid}) when not is_nil(user_uuid),
    do: :not_a_guest_cart

  defp guest_refusal(%Cart{session_id: session_id, items: items}) do
    cond do
      not is_binary(session_id) or String.starts_with?(session_id, "api:") -> :not_a_guest_cart
      items == [] -> :cart_empty
      true -> nil
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

  defp move_lines!(source, target, opts, announce_after_commit?) do
    language = Keyword.get(opts, :language)
    via = Keyword.get(opts, :via)
    add_opts = [language: language, via: via, broadcast: not announce_after_commit?]
    records = load_records(source.items, language)

    # Product-uuid order, like the writer: two moves (or a move and a write)
    # that share two products must not lock their rows crosswise.
    {moved_into, outcomes} =
      source.items
      |> Enum.sort_by(&(CartView.line_product_id(&1) || ""))
      |> Enum.reduce({target, []}, fn item, {cart, outcomes} ->
        case add_line(cart, item, records, add_opts) do
          {:ok, updated, quantity} -> {updated, [{item, {:moved, quantity}} | outcomes]}
          {:skipped, reason} -> {cart, [{item, {:skipped, reason}} | outcomes]}
        end
      end)

    outcomes = Enum.reverse(outcomes)
    keep_skipped? = Keyword.get(opts, :keep_skipped, false)
    report = report(outcomes, keep_skipped?)

    {source_after, changed?} =
      settle_source!(source, moved_into, outcomes, keep_skipped?, announce_after_commit?)

    {moved_into, report, source_after, changed?}
  end

  # `moved` counts the lines that went in (a capped one counts). A line that did
  # not go in is `skipped` with its reason; with `keep_skipped` the part of a
  # capped line that did not fit is skipped as well, because it stays behind.
  defp report(outcomes, keep_skipped?) do
    moved = Enum.count(outcomes, &match?({_item, {:moved, _quantity}}, &1))

    skipped =
      for {item, outcome} <- outcomes,
          reason = skip_reason(item, outcome, keep_skipped?),
          do: skipped_line(item, reason)

    %{moved: moved, skipped: skipped}
  end

  defp skip_reason(_item, {:skipped, reason}, _keep_skipped?), do: reason

  defp skip_reason(item, {:moved, quantity}, true) when quantity < item.quantity,
    do: :quantity_cap

  defp skip_reason(_item, {:moved, _quantity}, _keep_skipped?), do: nil

  # The default (the claim): the source is `merged` whatever was left behind,
  # and its lines stay on it as a record. With `keep_skipped` (the handoff) what
  # moved leaves the source and what did not stays, so the source is `merged`
  # only when nothing is left in it and otherwise stays active with its totals
  # recalculated. Returns the source as it stands and whether anything changed.
  defp settle_source!(source, target, _outcomes, false, preload?) do
    merged =
      source
      |> Cart.status_changeset("merged", %{merged_into_cart_uuid: target.uuid})
      |> repo().update!()

    {maybe_preload(merged, preload?), true}
  end

  defp settle_source!(source, target, outcomes, true, preload?) do
    changed? =
      Enum.reduce(outcomes, false, fn
        {item, {:moved, quantity}}, _changed when quantity >= item.quantity ->
          repo().delete!(item)
          true

        {item, {:moved, quantity}}, _changed ->
          item |> CartItem.changeset(%{quantity: item.quantity - quantity}) |> repo().update!()
          true

        {_item, {:skipped, _reason}}, changed ->
          changed
      end)

    if changed? do
      {settle_changed_source!(source, target, outcomes, preload?), true}
    else
      {source, false}
    end
  end

  defp settle_changed_source!(source, target, outcomes, preload?) do
    recalculated = Shop.recalculate_totals_keeping_currency!(source)

    emptied? =
      Enum.all?(outcomes, fn
        {item, {:moved, quantity}} -> quantity >= item.quantity
        {_item, {:skipped, _reason}} -> false
      end)

    settled =
      if emptied? do
        recalculated
        |> Cart.status_changeset("merged", %{merged_into_cart_uuid: target.uuid})
        |> repo().update!()
      else
        recalculated
      end

    maybe_preload(settled, preload?)
  end

  defp maybe_preload(cart, true), do: repo().preload(cart, @preloads, force: true)
  defp maybe_preload(cart, false), do: cart

  # One loader call for every product of the source: the records carry the
  # visibility state of the public API, the one rule of what may be carted.
  defp load_records(items, language) do
    Loader.load(
      Enum.map(items, &CartView.line_product_id/1),
      if(language, do: [language: language], else: [])
    )
  end

  @doc false
  # Every line of `cart` as a skipped line with `reason`: what a caller reports
  # when it could not move the cart at all.
  def skipped_lines(%Cart{items: items}, reason), do: Enum.map(items, &skipped_line(&1, reason))

  defp skipped_line(item, reason),
    do: %{product_uuid: CartView.line_product_id(item), name: item.product_title, reason: reason}

  defp add_line(cart, item, records, add_opts) do
    with product_id when is_binary(product_id) <- CartView.line_product_id(item),
         {:ok, product} <- listed_product(records, product_id),
         {:ok, specs} <- specs_for(product, item),
         quantity when quantity > 0 <- room_for(cart, product, specs, item.quantity) do
      add_checked(cart, product, quantity, specs, add_opts)
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
  defp add_checked(cart, product, quantity, specs, add_opts) do
    case Shop.add_to_cart(cart, product, quantity, [{:selected_specs, specs} | add_opts]) do
      {:ok, updated} ->
        {:ok, updated, quantity}

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
