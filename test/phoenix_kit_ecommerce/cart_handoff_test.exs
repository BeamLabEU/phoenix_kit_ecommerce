defmodule PhoenixKitEcommerce.CartHandoffTest do
  @moduledoc """
  The shop's half of core's cross-domain handoff: `handoff_snapshot/1` says
  what a guest carries to another domain, `handoff_apply/2` applies it there.
  Core calls both through `function_exported?`, with plain maps; they are
  tested here without core.

  A guest cart's uuid in the payload is a bearer secret: only a cart that is
  still active, belongs to no user and is not an API cart is ever adopted.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem

  setup do
    ensure_currencies!()
    %{p1: product!(), p2: product!()}
  end

  defp unique, do: System.unique_integer([:positive])
  defp session, do: "handoff-#{unique()}"

  defp cart_in(code, opts) do
    Currency.put_request_currency(code)
    {:ok, cart} = Shop.create_cart(opts)
    Currency.put_request_currency(nil)
    cart
  end

  defp fill!(cart, lines) do
    Enum.reduce(lines, cart, fn {product, quantity}, acc ->
      {:ok, updated} = Shop.add_to_cart(acc, product, quantity)
      updated
    end)
  end

  defp guest_cart!(lines, code \\ "USD"),
    do: code |> cart_in(session_id: session()) |> fill!(lines)

  defp reload(cart), do: Shop.get_cart(cart.uuid)
  defp payload(cart), do: %{"cart_uuid" => cart.uuid}
  defp nothing, do: %{moved: 0, skipped: []}

  defp active_carts_of(session_id),
    do: Repo.all(from(c in Cart, where: c.session_id == ^session_id and c.status == "active"))

  defp cart_count, do: Repo.aggregate(Cart, :count)

  defp quantities(cart),
    do: cart |> reload() |> Map.fetch!(:items) |> Map.new(&{&1.product_uuid, &1.quantity})

  defp stored(cart_uuid) do
    {Repo.get!(Cart, cart_uuid),
     Repo.all(from(i in CartItem, where: i.cart_uuid == ^cart_uuid, order_by: i.uuid))}
  end

  describe "handoff_snapshot/1" do
    test "a guest's non-empty active cart is named by uuid, JSON-safe", ctx do
      cart = guest_cart!([{ctx.p1, 2}])

      snapshot = Shop.handoff_snapshot(%{user_uuid: nil, shop_session_id: cart.session_id})

      assert snapshot == %{"cart_uuid" => cart.uuid}
      assert snapshot |> Jason.encode!() |> Jason.decode!() == snapshot
    end

    test "a signed-in user carries nothing, whatever their session holds", ctx do
      user = fixture_user()
      guest = guest_cart!([{ctx.p1, 1}])

      assert Shop.handoff_snapshot(%{user_uuid: user.uuid, shop_session_id: guest.session_id}) ==
               nil

      assert Shop.handoff_snapshot(%{user_uuid: user.uuid, shop_session_id: nil}) == nil
    end

    test "a guest with no cart, an empty cart or no session carries nothing" do
      assert Shop.handoff_snapshot(%{user_uuid: nil, shop_session_id: session()}) == nil

      empty = cart_in("USD", session_id: session())
      assert Shop.handoff_snapshot(%{user_uuid: nil, shop_session_id: empty.session_id}) == nil

      assert Shop.handoff_snapshot(%{user_uuid: nil, shop_session_id: nil}) == nil
      assert Shop.handoff_snapshot(%{user_uuid: nil, shop_session_id: ""}) == nil
    end

    test "only an ACTIVE cart is carried", ctx do
      for status <- ["converted", "converting", "abandoned", "merged"] do
        cart = guest_cart!([{ctx.p1, 1}])
        Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: status])

        assert Shop.handoff_snapshot(%{user_uuid: nil, shop_session_id: cart.session_id}) == nil,
               "a #{status} cart must not be carried"
      end
    end

    test "a cart that belongs to a user is not the guest's, even under the same session", ctx do
      user = fixture_user()
      session_id = session()
      {:ok, owned} = Shop.create_cart(user_uuid: user.uuid, session_id: session_id)
      fill!(owned, [{ctx.p1, 1}])

      assert Shop.handoff_snapshot(%{user_uuid: nil, shop_session_id: session_id}) == nil
    end

    test "an API cart is never carried", ctx do
      {:ok, api} = Shop.create_cart(session_id: "api:" <> String.duplicate("a", 20))
      fill!(api, [{ctx.p1, 1}])

      assert Shop.handoff_snapshot(%{user_uuid: nil, shop_session_id: api.session_id}) == nil
    end

    test "string keys work and anything that is not a context answers nil", ctx do
      cart = guest_cart!([{ctx.p1, 1}])

      assert Shop.handoff_snapshot(%{"user_uuid" => nil, "shop_session_id" => cart.session_id}) ==
               %{"cart_uuid" => cart.uuid}

      for junk <- [nil, %{}, "x", 5, [], %{shop_session_id: 5}, %{shop_session_id: %{}}] do
        assert Shop.handoff_snapshot(junk) == nil
      end
    end

    test "it reads only: nothing is written", ctx do
      cart = guest_cart!([{ctx.p1, 1}])
      before = stored(cart.uuid)

      _ = Shop.handoff_snapshot(%{user_uuid: nil, shop_session_id: cart.session_id})

      assert stored(cart.uuid) == before
    end
  end

  describe "handoff_apply/2 for a guest" do
    test "moves the cart into a new cart of the target session, in the target currency", ctx do
      source = guest_cart!([{ctx.p1, 3}, {ctx.p2, 1}])
      target_session = session()

      assert {:ok, %{moved: 2, skipped: []}} =
               Shop.handoff_apply(
                 %{user_uuid: nil, shop_session_id: target_session, currency: "EUR"},
                 payload(source)
               )

      assert [target] = active_carts_of(target_session)
      assert %{currency: "EUR", base_currency: "USD", user_uuid: nil} = target
      assert Decimal.equal?(target.exchange_rate, Decimal.new("0.909091"))
      assert quantities(target) == %{ctx.p1.uuid => 3, ctx.p2.uuid => 1}

      line = hd(reload(target).items)
      assert line.currency == "EUR"
      assert Decimal.equal?(line.unit_price, Decimal.new("9.09"))
      assert Decimal.equal?(line.base_unit_price, Decimal.new("10.00"))
      assert Decimal.equal?(reload(target).subtotal, Decimal.new("36.36"))

      merged = Repo.get!(Cart, source.uuid)
      assert merged.status == "merged"
      assert merged.merged_into_cart_uuid == target.uuid
    end

    test "the target already holds lines: they stay, the same product adds up", ctx do
      source = guest_cart!([{ctx.p1, 2}, {ctx.p2, 1}])
      target_session = session()
      existing = "EUR" |> cart_in(session_id: target_session) |> fill!([{ctx.p1, 4}])

      assert {:ok, %{moved: 2, skipped: []}} =
               Shop.handoff_apply(
                 %{user_uuid: nil, shop_session_id: target_session, currency: "EUR"},
                 payload(source)
               )

      assert quantities(existing) == %{ctx.p1.uuid => 6, ctx.p2.uuid => 1}
      assert [_only] = active_carts_of(target_session)
    end

    test "a target cart in another currency is re-denominated, its own lines included", ctx do
      source = guest_cart!([{ctx.p2, 1}])
      target_session = session()
      existing = "USD" |> cart_in(session_id: target_session) |> fill!([{ctx.p1, 1}])
      assert existing.currency == "USD"

      assert {:ok, %{moved: 1}} =
               Shop.handoff_apply(
                 %{user_uuid: nil, shop_session_id: target_session, currency: "EUR"},
                 payload(source)
               )

      cart = reload(existing)
      assert cart.currency == "EUR"
      assert Enum.all?(cart.items, &(&1.currency == "EUR"))
      assert Enum.all?(cart.items, &Decimal.equal?(&1.unit_price, Decimal.new("9.09")))
      assert Decimal.equal?(cart.subtotal, Decimal.new("18.18"))
    end

    test "a line that cannot be added is skipped and named", ctx do
      source = guest_cart!([{ctx.p1, 1}, {ctx.p2, 1}])
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      assert {:ok, %{moved: 1, skipped: [skipped]}} =
               Shop.handoff_apply(
                 %{user_uuid: nil, shop_session_id: session(), currency: "USD"},
                 payload(source)
               )

      assert skipped == %{
               product_uuid: ctx.p2.uuid,
               name: ctx.p2.title["en"],
               reason: :not_on_sale
             }
    end

    test "the same payload applied twice moves nothing the second time", ctx do
      source = guest_cart!([{ctx.p1, 2}])
      context = %{user_uuid: nil, shop_session_id: session(), currency: "EUR"}

      assert {:ok, %{moved: 1}} = Shop.handoff_apply(context, payload(source))
      assert {:ok, nothing()} == Shop.handoff_apply(context, payload(source))

      assert quantities(hd(active_carts_of(context.shop_session_id))) == %{ctx.p1.uuid => 2}
    end

    test "no payload and nothing to carry: nothing is created" do
      before = cart_count()

      assert {:ok, nothing()} ==
               Shop.handoff_apply(
                 %{user_uuid: nil, shop_session_id: session(), currency: "EUR"},
                 nil
               )

      assert cart_count() == before
    end

    test "with no currency the request's display currency is used", ctx do
      source = guest_cart!([{ctx.p1, 1}])
      target_session = session()

      Currency.put_request_currency("EUR")

      assert {:ok, %{moved: 1}} =
               Shop.handoff_apply(
                 %{user_uuid: nil, shop_session_id: target_session},
                 payload(source)
               )

      Currency.put_request_currency(nil)
      assert [%{currency: "EUR"}] = active_carts_of(target_session)
    end

    test "a currency the shop does not price in is refused and nothing moves", ctx do
      source = guest_cart!([{ctx.p1, 1}])
      before = stored(source.uuid)

      assert {:error, :currency_unavailable} =
               Shop.handoff_apply(
                 %{user_uuid: nil, shop_session_id: session(), currency: "XXX"},
                 payload(source)
               )

      assert stored(source.uuid) == before
    end
  end

  describe "handoff_apply/2 for a signed-in user" do
    test "the lines go into the user's own cart, which is brought into the currency", ctx do
      user = fixture_user()
      source = guest_cart!([{ctx.p2, 2}])
      own = "USD" |> cart_in(user_uuid: user.uuid, session_id: session()) |> fill!([{ctx.p1, 1}])

      assert {:ok, %{moved: 1, skipped: []}} =
               Shop.handoff_apply(
                 %{user_uuid: user.uuid, shop_session_id: session(), currency: "EUR"},
                 payload(source)
               )

      cart = reload(own)
      assert cart.currency == "EUR"
      assert quantities(own) == %{ctx.p1.uuid => 1, ctx.p2.uuid => 2}
      assert Decimal.equal?(cart.subtotal, Decimal.new("27.27"))
      assert Repo.get!(Cart, source.uuid).merged_into_cart_uuid == own.uuid
    end

    test "a user with no cart gets one, owned by the user, with the lines", ctx do
      user = fixture_user()
      source = guest_cart!([{ctx.p1, 2}])

      assert {:ok, %{moved: 1}} =
               Shop.handoff_apply(
                 %{user_uuid: user.uuid, shop_session_id: session(), currency: "EUR"},
                 payload(source)
               )

      assert %Cart{currency: "EUR"} =
               cart =
               Repo.one!(
                 from(c in Cart, where: c.user_uuid == ^user.uuid and c.status == "active")
               )

      assert quantities(cart) == %{ctx.p1.uuid => 2}
    end

    test "no payload: the user's cart in another currency is re-denominated", ctx do
      user = fixture_user()
      own = "USD" |> cart_in(user_uuid: user.uuid, session_id: session()) |> fill!([{ctx.p1, 3}])

      assert {:ok, nothing()} ==
               Shop.handoff_apply(
                 %{user_uuid: user.uuid, shop_session_id: session(), currency: "EUR"},
                 nil
               )

      cart = reload(own)
      assert cart.currency == "EUR"
      assert Decimal.equal?(cart.subtotal, Decimal.new("27.27"))
      assert [%{currency: "EUR"}] = cart.items
    end

    test "no payload and the cart already in that currency: nothing is written", ctx do
      user = fixture_user()
      own = "EUR" |> cart_in(user_uuid: user.uuid, session_id: session()) |> fill!([{ctx.p1, 1}])
      before = stored(own.uuid)

      assert {:ok, nothing()} ==
               Shop.handoff_apply(
                 %{user_uuid: user.uuid, shop_session_id: session(), currency: "EUR"},
                 nil
               )

      assert stored(own.uuid) == before
    end

    test "no payload and no cart: nothing is created" do
      user = fixture_user()
      before = cart_count()

      assert {:ok, nothing()} ==
               Shop.handoff_apply(
                 %{user_uuid: user.uuid, shop_session_id: session(), currency: "EUR"},
                 nil
               )

      assert cart_count() == before
    end
  end

  describe "handoff_apply/2 never adopts a cart it should not" do
    setup ctx do
      %{context: %{user_uuid: nil, shop_session_id: session(), currency: "EUR"}, p1: ctx.p1}
    end

    defp assert_untouched(context, cart) do
      before = stored(cart.uuid)
      carts_before = cart_count()

      assert {:ok, nothing()} == Shop.handoff_apply(context, payload(cart))

      assert stored(cart.uuid) == before
      assert cart_count() == carts_before
    end

    test "a cart that belongs to a user", %{context: context, p1: p1} do
      user = fixture_user()
      {:ok, owned} = Shop.create_cart(user_uuid: user.uuid, session_id: session())
      owned = fill!(owned, [{p1, 2}])

      assert_untouched(context, owned)
    end

    test "a cart that was converted, merged, abandoned or is converting",
         %{context: context, p1: p1} do
      for status <- ["converted", "merged", "abandoned", "converting"] do
        cart = guest_cart!([{p1, 1}])
        Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: status])

        assert_untouched(context, cart)
      end
    end

    test "a cart merged by an earlier apply", %{context: context, p1: p1} do
      cart = guest_cart!([{p1, 1}])
      assert {:ok, %{moved: 1}} = Shop.handoff_apply(context, payload(cart))

      assert_untouched(context, cart)
    end

    test "an API cart", %{context: context, p1: p1} do
      {:ok, api} = Shop.create_cart(session_id: "api:" <> String.duplicate("b", 20))
      api = fill!(api, [{p1, 1}])

      assert_untouched(context, api)
    end

    test "an empty guest cart", %{context: context} do
      empty = cart_in("USD", session_id: session())

      assert_untouched(context, empty)
    end

    test "the target's own cart", %{p1: p1} do
      own = "USD" |> cart_in(session_id: session()) |> fill!([{p1, 2}])
      context = %{user_uuid: nil, shop_session_id: own.session_id, currency: "USD"}

      assert_untouched(context, own)
      assert reload(own).status == "active"
    end

    test "garbage", %{context: context, p1: p1} do
      cart = guest_cart!([{p1, 1}])
      before = {stored(cart.uuid), cart_count()}

      for junk <- [
            nil,
            %{},
            "x",
            5,
            [],
            [cart.uuid],
            %{"cart_uuid" => nil},
            %{"cart_uuid" => 5},
            %{"cart_uuid" => ""},
            %{"cart_uuid" => "not-a-uuid"},
            %{"cart_uuid" => Ecto.UUID.generate()},
            %{"cart_uuid" => %{}},
            %{"other" => cart.uuid},
            %{cart_uuid: nil}
          ] do
        assert {:ok, nothing()} == Shop.handoff_apply(context, junk),
               "payload #{inspect(junk)} must be a quiet no-op"
      end

      assert {stored(cart.uuid), cart_count()} == before
    end

    test "an atom-keyed payload names the cart as well", %{context: context, p1: p1} do
      cart = guest_cart!([{p1, 1}])

      assert {:ok, %{moved: 1}} = Shop.handoff_apply(context, %{cart_uuid: cart.uuid})
    end

    test "a context without an identity is an error, not a crash", %{p1: p1} do
      cart = guest_cart!([{p1, 1}])

      assert {:error, :invalid_context} =
               Shop.handoff_apply(
                 %{user_uuid: nil, shop_session_id: nil, currency: "EUR"},
                 payload(cart)
               )

      assert {:error, :invalid_context} = Shop.handoff_apply(nil, payload(cart))
      assert {:error, :invalid_context} = Shop.handoff_apply(%{}, payload(cart))
      assert reload(cart).status == "active"
    end
  end

  describe "locking" do
    test "the target's identity and the source's are locked while lines move", ctx do
      user = fixture_user()
      source = guest_cart!([{ctx.p1, 1}])
      target_session = session()

      assert {:ok, {:ok, %{moved: 1}, true, true, true}} =
               Repo.transaction(fn ->
                 result =
                   Shop.handoff_apply(
                     %{user_uuid: user.uuid, shop_session_id: target_session, currency: "EUR"},
                     payload(source)
                   )

                 {:ok, report} = result

                 {:ok, report, advisory_lock_held?("shop_cart_user:" <> user.uuid),
                  advisory_lock_held?("shop_cart_session:" <> target_session),
                  advisory_lock_held?("shop_cart_session:" <> source.session_id)}
               end)
    end
  end
end
