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
  alias PhoenixKitEcommerce.Events

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

  defp drain_events(acc \\ []) do
    receive do
      {:cart_updated, _cart} = event -> drain_events([event | acc])
      {:item_added, _cart, _item} = event -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Everything a refused move must leave exactly as it was.
  defp world(source, target) do
    {Repo.get!(Cart, source.uuid), stored_items(source.uuid), Repo.get!(Cart, target.uuid),
     stored_items(target.uuid)}
  end

  describe "the ownership contract" do
    # `move_cart_lines/3` does not know whose carts they are: the caller has
    # settled that the shopper may hand the source over. `guest_source: true`
    # makes it check, under the row lock, that the source is a guest cart.
    test "a source that has a user is refused with guest_source: true", ctx do
      user = fixture_user()
      {:ok, source} = Shop.create_cart(user_uuid: user.uuid, session_id: "move-#{unique()}")
      source = fill!(source, [{ctx.p1, 1}])
      target = cart_in("USD")
      before = world(source, target)

      assert {:error, :not_a_guest_cart} =
               Shop.move_cart_lines(source, target, guest_source: true)

      assert world(source, target) == before
    end

    test "a source that gained a user between the caller's read and the lock is refused", ctx do
      user = fixture_user()
      source = usd_source([{ctx.p1, 1}])
      target = cart_in("USD")

      # What the caller holds says "guest"; the row, by the time it is locked, does not.
      assert source.user_uuid == nil
      Repo.update_all(from(c in Cart, where: c.uuid == ^source.uuid), set: [user_uuid: user.uuid])
      before = world(source, target)

      assert {:error, :not_a_guest_cart} =
               Shop.move_cart_lines(source, target, guest_source: true)

      assert world(source, target) == before
    end

    test "without the option the same source moves: the claim's behaviour is unchanged", ctx do
      user = fixture_user()
      source = usd_source([{ctx.p1, 1}])
      target = cart_in("USD")
      Repo.update_all(from(c in Cart, where: c.uuid == ^source.uuid), set: [user_uuid: user.uuid])

      assert {:ok, _, %{moved: 1}} = Shop.move_cart_lines(source, target, [])
      assert Repo.get!(Cart, source.uuid).status == "merged"
    end

    test "an API cart is refused with guest_source: true", ctx do
      {:ok, api} = Shop.create_cart(session_id: "api:" <> String.duplicate("a", 20))
      api = fill!(api, [{ctx.p1, 1}])
      target = cart_in("USD")
      before = world(api, target)

      assert {:error, :not_a_guest_cart} = Shop.move_cart_lines(api, target, guest_source: true)
      assert world(api, target) == before
    end

    test "an empty source is refused with guest_source: true and is not merged" do
      source = cart_in("USD")
      target = cart_in("USD")
      before = world(source, target)

      assert {:error, :cart_empty} = Shop.move_cart_lines(source, target, guest_source: true)
      assert world(source, target) == before
    end

    test "a guest source goes through with guest_source: true", ctx do
      source = usd_source([{ctx.p1, 2}])
      target = cart_in("USD")

      assert {:ok, _, %{moved: 1, skipped: []}} =
               Shop.move_cart_lines(source, target, guest_source: true)

      assert Repo.get!(Cart, source.uuid).status == "merged"
    end

    test "a source merged into this very target before is still a quiet no-op", ctx do
      source = usd_source([{ctx.p1, 2}])
      target = cart_in("USD")
      opts = [guest_source: true]

      assert {:ok, _, %{moved: 1}} = Shop.move_cart_lines(source, target, opts)
      assert {:ok, _, %{moved: 0, skipped: []}} = Shop.move_cart_lines(source, target, opts)
    end
  end

  describe "keep_skipped: true" do
    # A line that cannot be moved is not lost: it stays in the source, which is
    # `merged` only when nothing is left in it.
    test "a skipped line stays in the source, which stays active with its totals recalculated",
         ctx do
      source = usd_source([{ctx.p1, 1}, {ctx.p2, 2}])
      target = cart_in("EUR")
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      assert {:ok, _, %{moved: 1, skipped: [skipped]}} =
               Shop.move_cart_lines(source, target, keep_skipped: true)

      assert skipped.product_uuid == ctx.p2.uuid
      assert skipped.reason == :not_on_sale

      row = Repo.get!(Cart, source.uuid)
      assert row.status == "active"
      assert row.merged_into_cart_uuid == nil
      assert [left] = stored_items(source.uuid)
      assert left.product_uuid == ctx.p2.uuid and left.quantity == 2
      assert row.items_count == 2
      assert Decimal.equal?(row.subtotal, Decimal.new("20.00"))
      assert Decimal.equal?(row.total, Decimal.new("20.00"))
      assert row.currency == "USD"

      assert [only] = reload(target).items
      assert only.product_uuid == ctx.p1.uuid
    end

    test "when every line moved the source is merged and holds nothing", ctx do
      source = usd_source([{ctx.p1, 1}, {ctx.p2, 2}])
      target = cart_in("USD")

      assert {:ok, _, %{moved: 2, skipped: []}} =
               Shop.move_cart_lines(source, target, keep_skipped: true)

      row = Repo.get!(Cart, source.uuid)
      assert row.status == "merged"
      assert row.merged_into_cart_uuid == target.uuid
      assert stored_items(source.uuid) == []
      assert row.items_count == 0
      assert Decimal.equal?(row.total, Decimal.new("0"))
    end

    test "when nothing could move, nothing is written to either cart", ctx do
      source = usd_source([{ctx.p1, 1}, {ctx.p2, 1}])
      target = cart_in("USD")
      {:ok, _} = Shop.update_product(ctx.p1, %{"status" => "archived"})
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})
      before = world(source, target)

      assert {:ok, same, %{moved: 0, skipped: [_, _]}} =
               Shop.move_cart_lines(source, target, keep_skipped: true)

      assert same.uuid == target.uuid
      assert world(source, target) == before
    end

    test "the part of a capped line that did not fit stays in the source", ctx do
      max = CartWriter.max_quantity()
      source = usd_source([{ctx.p1, 5}])
      target = "USD" |> cart_in() |> fill!([{ctx.p1, max - 2}])

      assert {:ok, _, %{moved: 1, skipped: [skipped]}} =
               Shop.move_cart_lines(source, target, keep_skipped: true)

      assert skipped.product_uuid == ctx.p1.uuid
      assert skipped.reason == :quantity_cap

      assert [%{quantity: 3}] = stored_items(source.uuid)

      assert [%{quantity: ^max}] = reload(target).items
      row = Repo.get!(Cart, source.uuid)
      assert row.status == "active"
      assert row.items_count == 3
      assert Decimal.equal?(row.subtotal, Decimal.new("30.00"))
    end

    test "what stayed can be moved by a later call, which then merges the source", ctx do
      source = usd_source([{ctx.p1, 1}, {ctx.p2, 2}])
      target = cart_in("USD")
      {:ok, p2} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      assert {:ok, _, %{moved: 1, skipped: [_]}} =
               Shop.move_cart_lines(source, target, keep_skipped: true)

      {:ok, _} = Shop.update_product(p2, %{"status" => "active"})

      assert {:ok, _, %{moved: 1, skipped: []}} =
               Shop.move_cart_lines(source, target, keep_skipped: true)

      assert Repo.get!(Cart, source.uuid).status == "merged"
      assert quantities_of(target) == %{ctx.p1.uuid => 1, ctx.p2.uuid => 2}
    end

    test "without the option a skipped line is dropped with the merged source (the claim)",
         ctx do
      source = usd_source([{ctx.p1, 1}, {ctx.p2, 2}])
      target = cart_in("USD")
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      assert {:ok, _, %{moved: 1, skipped: [_]}} = Shop.move_cart_lines(source, target, [])

      assert Repo.get!(Cart, source.uuid).status == "merged"
      assert length(stored_items(source.uuid)) == 2
    end
  end

  defp quantities_of(cart),
    do: cart |> reload() |> Map.fetch!(:items) |> Map.new(&{&1.product_uuid, &1.quantity})

  describe "events" do
    setup do
      source = cart_in("USD")
      target = cart_in("EUR")
      :ok = Events.subscribe_to_session_cart(source.session_id)
      :ok = Events.subscribe_to_session_cart(target.session_id)
      %{source: source, target: target}
    end

    test "one cart_updated per affected cart, after the commit; no line-by-line events", ctx do
      source = fill!(ctx.source, [{ctx.p1, 1}, {ctx.p2, 2}])
      _ = drain_events()

      assert {:ok, _, %{moved: 2}} = Shop.move_cart_lines(source, ctx.target, [])

      events = drain_events()
      assert [] = for({:item_added, _, _} = event <- events, do: event)

      target_uuid = ctx.target.uuid
      source_uuid = source.uuid

      assert [{:cart_updated, %Cart{uuid: ^target_uuid, items_count: 3}}] =
               for({:cart_updated, %Cart{uuid: ^target_uuid}} = e <- events, do: e)

      assert [{:cart_updated, %Cart{uuid: ^source_uuid, status: "merged"}}] =
               for({:cart_updated, %Cart{uuid: ^source_uuid}} = e <- events, do: e)
    end

    test "the source that stays active is announced as it stands", ctx do
      source = fill!(ctx.source, [{ctx.p1, 1}, {ctx.p2, 2}])
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})
      _ = drain_events()

      assert {:ok, _, %{moved: 1}} =
               Shop.move_cart_lines(source, ctx.target, keep_skipped: true)

      source_uuid = source.uuid

      assert [{:cart_updated, %Cart{uuid: ^source_uuid, status: "active", items_count: 2}}] =
               for({:cart_updated, %Cart{uuid: ^source_uuid}} = e <- drain_events(), do: e)
    end

    test "nothing moved, nothing announced", ctx do
      source = fill!(ctx.source, [{ctx.p1, 1}])
      {:ok, _} = Shop.update_product(ctx.p1, %{"status" => "archived"})
      _ = drain_events()

      assert {:ok, _, %{moved: 0}} = Shop.move_cart_lines(source, ctx.target, keep_skipped: true)

      assert drain_events() == []
    end

    test "a refused move announces nothing", ctx do
      source = fill!(ctx.source, [{ctx.p1, 1}])

      Repo.update_all(from(c in Cart, where: c.uuid == ^ctx.target.uuid),
        set: [status: "abandoned"]
      )

      _ = drain_events()

      assert {:error, :cart_not_active} = Shop.move_cart_lines(source, ctx.target, [])

      assert drain_events() == []
    end

    # The limit, kept on purpose: the caller owns the transaction (the claim
    # does), so the move cannot know when it commits and sends nothing of its
    # own: the lines are announced one by one, as `add_to_cart/4` does.
    test "inside the caller's transaction the lines are announced as they are added", ctx do
      source = fill!(ctx.source, [{ctx.p1, 1}, {ctx.p2, 2}])
      _ = drain_events()

      assert {:ok, {:ok, _, %{moved: 2}}} =
               Repo.transaction(fn -> Shop.move_cart_lines(source, ctx.target, []) end)

      events = drain_events()
      assert [_, _] = for({:item_added, _, _} = event <- events, do: event)
    end
  end

  describe ":busy" do
    setup do
      [first, second] = Enum.sort_by([product!(), product!()], & &1.uuid)
      source = usd_source([{first, 1}, {second, 2}])
      target = cart_in("EUR")
      :ok = Events.subscribe_to_session_cart(source.session_id)
      :ok = Events.subscribe_to_session_cart(target.session_id)
      _ = drain_events()
      %{first: first, second: second, source: source, target: target}
    end

    # The second line's product left the shop after the check: `add_to_cart`
    # refuses it inside its own transaction, which dooms the move. The first
    # line was already added: it must go, and no tab may have been told of it.
    test "an answer of add_to_cart that is not the line's own rolls the whole move back", ctx do
      before = world(ctx.source, ctx.target)

      after_first_query("INSERT", "phoenix_kit_shop_cart_items", fn ->
        {:ok, _} = Shop.update_product(ctx.second, %{"status" => "archived"})
      end)

      assert {:error, :busy} = Shop.move_cart_lines(ctx.source, ctx.target, keep_skipped: true)

      assert world(ctx.source, ctx.target) == before
      assert drain_events() == []
      # the connection is still usable
      assert %{rows: [[1]]} = Repo.query!("SELECT 1")
    end

    test "a deadlock the database resolves against the move is :busy, nothing moved", ctx do
      before = world(ctx.source, ctx.target)

      Repo.query!("""
      CREATE FUNCTION pk_test_raise_deadlock() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'simulated deadlock' USING ERRCODE = '40P01'; END
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER pk_test_raise_deadlock BEFORE INSERT ON phoenix_kit_shop_cart_items
      FOR EACH ROW EXECUTE FUNCTION pk_test_raise_deadlock()
      """)

      assert {:error, :busy} = Shop.move_cart_lines(ctx.source, ctx.target, [])

      assert world(ctx.source, ctx.target) == before
      assert drain_events() == []
    end
  end

  describe "via" do
    # `via: :assistant` keeps `add_to_cart/4` from telling the shop's operators
    # about every moved line; any other value (the default) lets it.
    setup do
      PhoenixKit.Settings.update_setting_with_module("shop_notify_cart_item", "true", "shop")
      # the first user registered in the sandbox is the owner who is told
      _owner = fixture_user()
      :ok
    end

    test "the default lets add_to_cart notify, :assistant does not", ctx do
      # The lines are put in the sources first: filling a cart notifies too.
      {first, first_target} = {usd_source([{ctx.p1, 1}]), cart_in("USD")}
      {second, second_target} = {usd_source([{ctx.p2, 1}]), cart_in("USD")}
      before = count_notifications("shop.cart_item_added")

      assert {:ok, _, %{moved: 1}} = Shop.move_cart_lines(first, first_target, [])
      assert count_notifications("shop.cart_item_added") == before + 1

      assert {:ok, _, %{moved: 1}} =
               Shop.move_cart_lines(second, second_target, via: :assistant)

      assert count_notifications("shop.cart_item_added") == before + 1
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
