defmodule PhoenixKitEcommerce.CartMoveLinesTest do
  @moduledoc """
  `PhoenixKitEcommerce.move_cart_lines/3`: every line of a source cart goes
  into a target cart through the normal add-to-cart path, so it is re-read,
  re-validated (availability, options, stock, the quantity cap) and priced at
  the TARGET cart's currency and the CURRENT price of the product. What the
  source line keeps is the quantity and the options, not the price. The source
  cart ends `merged` into the target.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.Cart

  setup do
    ensure_currencies!()
    %{p1: product!(), p2: product!()}
  end

  defp unique, do: System.unique_integer([:positive])

  defp cart_in(code, opts \\ []) do
    Currency.put_request_currency(code)
    {:ok, cart} = Shop.create_cart(Keyword.put_new(opts, :session_id, "move-#{unique()}"))
    Currency.put_request_currency(nil)
    cart
  end

  # `lines` is [{product, quantity}] or [{product, quantity, selected_specs}].
  defp fill!(cart, lines) do
    Enum.reduce(lines, cart, fn line, acc ->
      {product, quantity, specs} =
        case line do
          {product, quantity} -> {product, quantity, %{}}
          {_product, _quantity, _specs} = full -> full
        end

      {:ok, updated} = Shop.add_to_cart(acc, product, quantity, selected_specs: specs)
      updated
    end)
  end

  defp usd_source(lines), do: "USD" |> cart_in() |> fill!(lines)
  defp reload(cart), do: Shop.get_cart(cart.uuid)

  defp lines_of(cart) do
    cart
    |> reload()
    |> Map.fetch!(:items)
    |> Map.new(&{{&1.product_uuid, &1.selected_specs}, &1})
  end

  defp stored_items(cart_uuid) do
    Repo.all(
      from(i in PhoenixKitEcommerce.CartItem, where: i.cart_uuid == ^cart_uuid, order_by: i.uuid)
    )
  end

  describe "moving lines" do
    test "a USD source into a EUR target: lines priced in EUR at the target's rate", ctx do
      source = usd_source([{ctx.p1, 3}, {ctx.p2, 1}])
      target = cart_in("EUR")

      assert {:ok, moved_into, %{moved: 2, skipped: []}} =
               Shop.move_cart_lines(source, target, [])

      assert %{currency: "EUR", base_currency: "USD"} = moved_into
      assert Decimal.equal?(moved_into.exchange_rate, Decimal.new("0.909091"))

      lines = lines_of(target)
      line = Map.fetch!(lines, {ctx.p1.uuid, %{}})
      # 10.00 x 0.909091 = 9.09091 -> 9.09, base amount kept exact
      assert Decimal.equal?(line.unit_price, Decimal.new("9.09"))
      assert Decimal.equal?(line.base_unit_price, Decimal.new("10.00"))
      assert line.currency == "EUR"
      assert line.quantity == 3
      assert Map.fetch!(lines, {ctx.p2.uuid, %{}}).quantity == 1

      assert Decimal.equal?(moved_into.subtotal, Decimal.new("36.36"))
      assert Decimal.equal?(reload(target).subtotal, Decimal.new("36.36"))
    end

    test "the source ends merged into the target", ctx do
      source = usd_source([{ctx.p1, 1}])
      target = cart_in("USD")

      assert {:ok, _, %{moved: 1}} = Shop.move_cart_lines(source, target, [])

      row = Repo.get!(Cart, source.uuid)
      assert row.status == "merged"
      assert row.merged_into_cart_uuid == target.uuid
      assert Repo.get!(Cart, target.uuid).status == "active"
    end

    test "the price is the product's CURRENT one, not the source line's", ctx do
      source = usd_source([{ctx.p1, 1}])
      {:ok, _} = Shop.update_product(ctx.p1, %{"price" => Decimal.new("25.00")})
      target = cart_in("USD")

      assert {:ok, _, %{moved: 1}} = Shop.move_cart_lines(source, target, [])

      line = Map.fetch!(lines_of(target), {ctx.p1.uuid, %{}})
      assert Decimal.equal?(line.unit_price, Decimal.new("25.00"))
      assert Decimal.equal?(line.base_unit_price, Decimal.new("25.00"))
    end

    test "quantity and options are kept" do
      shirt = product_with_options!(%{"color" => ["Red", "Blue"]})
      source = usd_source([{shirt, 4, %{"color" => "Red"}}, {shirt, 2, %{"color" => "Blue"}}])
      target = cart_in("USD")

      assert {:ok, _, %{moved: 2, skipped: []}} = Shop.move_cart_lines(source, target, [])

      lines = lines_of(target)
      assert Map.fetch!(lines, {shirt.uuid, %{"color" => "Red"}}).quantity == 4
      assert Map.fetch!(lines, {shirt.uuid, %{"color" => "Blue"}}).quantity == 2
    end

    test "a product the target already holds adds up and keeps the target line's price", ctx do
      source = usd_source([{ctx.p1, 3}])
      target = "USD" |> cart_in() |> fill!([{ctx.p1, 2}])
      {:ok, _} = Shop.update_product(ctx.p1, %{"price" => Decimal.new("25.00")})

      assert {:ok, _, %{moved: 1, skipped: []}} = Shop.move_cart_lines(source, target, [])

      assert [line] = reload(target).items
      assert line.quantity == 5
      assert Decimal.equal?(line.unit_price, Decimal.new("10.00"))
    end

    test "the quantity is capped as the cart API caps it", ctx do
      max = CartWriter.max_quantity()
      source = usd_source([{ctx.p1, 5}])
      target = "USD" |> cart_in() |> fill!([{ctx.p1, max - 2}])

      assert {:ok, _, %{moved: 1, skipped: []}} = Shop.move_cart_lines(source, target, [])

      assert [line] = reload(target).items
      assert line.quantity == max
    end

    test "a line the target already holds at the cap is skipped and named", ctx do
      max = CartWriter.max_quantity()
      source = usd_source([{ctx.p1, 1}, {ctx.p2, 1}])
      target = "USD" |> cart_in() |> fill!([{ctx.p1, max}])

      assert {:ok, _, %{moved: 1, skipped: [skipped]}} = Shop.move_cart_lines(source, target, [])

      assert skipped.product_uuid == ctx.p1.uuid
      assert skipped.name == ctx.p1.title["en"]
      assert skipped.reason == :quantity_cap
    end

    test "a product that is no longer for sale is skipped and named; the rest moves", ctx do
      source = usd_source([{ctx.p1, 1}, {ctx.p2, 2}])
      target = cart_in("USD")
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      assert {:ok, _, %{moved: 1, skipped: [skipped]}} = Shop.move_cart_lines(source, target, [])

      assert skipped.product_uuid == ctx.p2.uuid
      assert skipped.name == ctx.p2.title["en"]
      assert skipped.reason == :not_on_sale
      assert [only] = reload(target).items
      assert only.product_uuid == ctx.p1.uuid
      # the source is merged all the same: the buyer was told what was left behind
      assert Repo.get!(Cart, source.uuid).status == "merged"
    end

    test "a product that was deleted is skipped by name, with no product to point at", ctx do
      source = usd_source([{ctx.p1, 1}, {ctx.p2, 1}])
      target = cart_in("USD")
      {:ok, _} = Shop.delete_product(ctx.p2)

      assert {:ok, _, %{moved: 1, skipped: [skipped]}} = Shop.move_cart_lines(source, target, [])

      assert skipped.product_uuid == nil
      assert skipped.name == ctx.p2.title["en"]
      assert skipped.reason == :not_found
    end

    test "an option that is no longer offered skips the line" do
      shirt = product_with_options!(%{"color" => ["Red", "Blue"]})
      other = product!()
      source = usd_source([{shirt, 2, %{"color" => "Red"}}, {other, 1}])
      target = cart_in("USD")

      {:ok, _} =
        Shop.update_product(shirt, %{"metadata" => %{"_option_values" => %{"color" => ["Blue"]}}})

      assert {:ok, _, %{moved: 1, skipped: [skipped]}} = Shop.move_cart_lines(source, target, [])

      assert skipped.product_uuid == shirt.uuid
      assert skipped.reason == :invalid_options
    end

    test "a refusal add_to_cart makes for good skips the line with its reason", ctx do
      foreign = product!(%{"currency" => "EUR"})
      source = usd_source([{ctx.p1, 1}, {foreign, 1}])
      target = cart_in("USD")
      put_setting!("shop_enforce_product_currency", true)

      assert {:ok, _, %{moved: 1, skipped: [skipped]}} = Shop.move_cart_lines(source, target, [])

      assert skipped.product_uuid == foreign.uuid
      assert skipped.reason == :currency_mismatch
    end

    test "lines go in in product-uuid order, whatever order the source holds them" do
      products = Enum.sort_by([product!(), product!(), product!()], & &1.uuid)
      source = usd_source(products |> Enum.reverse() |> Enum.map(&{&1, 1}))
      target = cart_in("USD")

      inserted =
        inserted_item_products(products, fn ->
          assert {:ok, _, %{moved: 3}} = Shop.move_cart_lines(source, target, [])
        end)

      assert inserted == Enum.map(products, & &1.uuid)
    end

    test "an empty source moves nothing and is merged", ctx do
      source = cart_in("USD")
      target = "USD" |> cart_in() |> fill!([{ctx.p1, 1}])

      assert {:ok, same, %{moved: 0, skipped: []}} = Shop.move_cart_lines(source, target, [])

      assert same.uuid == target.uuid
      assert [_] = same.items
      assert Repo.get!(Cart, source.uuid).status == "merged"
    end
  end

  describe "refusals" do
    test "a cart cannot be moved into itself", ctx do
      cart = usd_source([{ctx.p1, 2}])
      before = {Repo.get!(Cart, cart.uuid), stored_items(cart.uuid)}

      assert {:error, :same_cart} = Shop.move_cart_lines(cart, cart, [])

      assert {Repo.get!(Cart, cart.uuid), stored_items(cart.uuid)} == before
    end

    for status <- ["converted", "converting", "abandoned", "merged"] do
      test "a #{status} source is refused and nothing changes", ctx do
        source = usd_source([{ctx.p1, 1}])
        target = cart_in("USD")

        Repo.update_all(from(c in Cart, where: c.uuid == ^source.uuid),
          set: [status: unquote(status)]
        )

        before = {Repo.get!(Cart, source.uuid), stored_items(target.uuid)}

        assert {:error, :cart_not_active} = Shop.move_cart_lines(source, target, [])

        assert {Repo.get!(Cart, source.uuid), stored_items(target.uuid)} == before
      end

      test "a #{status} target is refused and the source stays active", ctx do
        source = usd_source([{ctx.p1, 1}])
        target = cart_in("USD")

        Repo.update_all(from(c in Cart, where: c.uuid == ^target.uuid),
          set: [status: unquote(status)]
        )

        assert {:error, :cart_not_active} = Shop.move_cart_lines(source, target, [])

        assert Repo.get!(Cart, source.uuid).status == "active"
        assert stored_items(target.uuid) == []
      end
    end

    test "a cart that is gone is :cart_not_found", ctx do
      source = usd_source([{ctx.p1, 1}])
      target = cart_in("USD")
      Repo.delete_all(from(c in Cart, where: c.uuid == ^target.uuid))

      assert {:error, :cart_not_found} = Shop.move_cart_lines(source, target, [])
      assert Repo.get!(Cart, source.uuid).status == "active"
    end
  end

  describe "idempotence" do
    test "a second call moves nothing and changes nothing", ctx do
      source = usd_source([{ctx.p1, 3}])
      target = cart_in("EUR")

      assert {:ok, _, %{moved: 1}} = Shop.move_cart_lines(source, target, [])
      after_first = {Repo.get!(Cart, target.uuid), stored_items(target.uuid)}

      assert {:ok, again, %{moved: 0, skipped: []}} = Shop.move_cart_lines(source, target, [])

      assert again.uuid == target.uuid
      assert [%{quantity: 3}] = again.items
      assert {Repo.get!(Cart, target.uuid), stored_items(target.uuid)} == after_first
    end

    test "a source merged into ANOTHER cart is not moved again", ctx do
      source = usd_source([{ctx.p1, 1}])
      first = cart_in("USD")
      second = cart_in("USD")

      assert {:ok, _, %{moved: 1}} = Shop.move_cart_lines(source, first, [])
      assert {:error, :cart_not_active} = Shop.move_cart_lines(source, second, [])
      assert stored_items(second.uuid) == []
    end
  end

  describe "locking" do
    test "identity locks: the user key, then the session keys sorted (target after source)" do
      user = fixture_user()
      source = cart_in("USD", session_id: "move-a-#{unique()}")
      target = cart_in("USD", user_uuid: user.uuid, session_id: "move-b-#{unique()}")
      source = fill!(source, [{product!(), 1}])

      keys = lock_keys(fn -> {:ok, _, _} = Shop.move_cart_lines(source, target, []) end)

      assert keys == [
               "shop_cart_user:" <> user.uuid,
               "shop_cart_session:" <> source.session_id,
               "shop_cart_session:" <> target.session_id
             ]
    end

    test "identity locks: the same order when the target's session sorts first" do
      user = fixture_user()
      target = cart_in("USD", user_uuid: user.uuid, session_id: "move-a-#{unique()}")
      source = cart_in("USD", session_id: "move-b-#{unique()}")
      source = fill!(source, [{product!(), 1}])

      keys = lock_keys(fn -> {:ok, _, _} = Shop.move_cart_lines(source, target, []) end)

      assert keys == [
               "shop_cart_user:" <> user.uuid,
               "shop_cart_session:" <> target.session_id,
               "shop_cart_session:" <> source.session_id
             ]
    end

    test "two guest carts: session keys sorted, not in argument order" do
      for {source_session, target_session} <- [{"move-a", "move-b"}, {"move-b", "move-a"}] do
        n = unique()
        source = cart_in("USD", session_id: "#{source_session}-#{n}")
        target = cart_in("USD", session_id: "#{target_session}-#{n}")
        source = fill!(source, [{product!(), 1}])

        keys = lock_keys(fn -> {:ok, _, _} = Shop.move_cart_lines(source, target, []) end)

        assert keys == Enum.sort(keys)
        assert length(keys) == 2
      end
    end

    test "both cart rows are locked before the first line is added" do
      source = fill!(cart_in("USD"), [{product!(), 1}])
      target = cart_in("USD")

      queries = trace(fn -> {:ok, _, _} = Shop.move_cart_lines(source, target, []) end)

      lock_at =
        Enum.find_index(queries, fn {source_table, query} ->
          source_table == "phoenix_kit_shop_carts" and query =~ "FOR UPDATE"
        end)

      first_insert =
        Enum.find_index(queries, fn {table, query} ->
          table == "phoenix_kit_shop_cart_items" and String.starts_with?(query, "INSERT")
        end)

      assert is_integer(lock_at) and is_integer(first_insert)
      assert lock_at < first_insert
    end
  end

  # --- tracing -----------------------------------------------------------------

  defp trace(fun) do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        send(test, {:query, meta.source, String.trim_leading(meta.query), meta.params})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain([])
  end

  defp drain(acc) do
    receive do
      {:query, source, query, params} -> drain([{source, query, params} | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.map(fn {source, query, _} -> {source, query} end)
    end
  end

  # The identity keys the call locked, in the order it first took them.
  defp lock_keys(fun) do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta.query =~ "pg_advisory_xact_lock", do: send(test, {:lock, hd(meta.params)})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect_locks([]) |> Enum.uniq()
  end

  defp collect_locks(acc) do
    receive do
      {:lock, key} -> collect_locks([key | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
