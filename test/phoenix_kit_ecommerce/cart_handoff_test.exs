defmodule PhoenixKitEcommerce.CartHandoffTest do
  @moduledoc """
  The shop's half of core's cross-domain handoff: `handoff_snapshot/1` says
  what a guest carries to another domain, `handoff_apply/2` applies it there.
  Core calls both through `function_exported?` with plain maps; they are tested
  here without core, with the plain maps they have always accepted and with the
  contexts core builds (`:user_uuid`, `:session`, `:cookies`, and on the target
  `:host` and `:locale`).

  The payload names a guest cart by uuid, and a payload is data: only a cart
  that is still active, belongs to no user and is not an API cart is ever
  adopted. A line that cannot be carried is not lost: it stays in the guest's
  cart.
  Neither function raises, whatever it is handed.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Test.Endpoint
  alias PhoenixKitEcommerce.Web.Plugs.ShopSession

  # Russian and Ukrainian wording as code points: no Cyrillic outside the
  # catalogues.
  @ru_came "\u{412}\u{430}\u{448}\u{430} \u{43A}\u{43E}\u{440}\u{437}\u{438}\u{43D}\u{430} \u{43F}\u{435}\u{440}\u{435}\u{43D}\u{435}\u{441}\u{435}\u{43D}\u{430}:"
  @ru_forms {"\u{442}\u{43E}\u{432}\u{430}\u{440}", "\u{442}\u{43E}\u{432}\u{430}\u{440}\u{430}",
             "\u{442}\u{43E}\u{432}\u{430}\u{440}\u{43E}\u{432}"}
  @uk_came "\u{412}\u{430}\u{448} \u{43A}\u{43E}\u{448}\u{438}\u{43A} \u{43F}\u{435}\u{440}\u{435}\u{43D}\u{435}\u{441}\u{435}\u{43D}\u{43E}:"
  @uk_forms {"\u{442}\u{43E}\u{432}\u{430}\u{440}", "\u{442}\u{43E}\u{432}\u{430}\u{440}\u{438}",
             "\u{442}\u{43E}\u{432}\u{430}\u{440}\u{456}\u{432}"}

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

  # What core hands the hooks (`PhoenixKit.Module.handoff_snapshot/1` and
  # `handoff_apply/2`): no shop-specific keys, only the request's own session
  # and cookies.
  defp core_snapshot_context(overrides \\ []),
    do: Map.merge(%{user_uuid: nil, session: %{}, cookies: %{}}, Map.new(overrides))

  defp core_apply_context(overrides \\ []),
    do:
      Map.merge(
        %{user_uuid: nil, session: %{}, cookies: %{}, host: "shop.de", locale: "de"},
        Map.new(overrides)
      )

  defp secret, do: Endpoint.config(:secret_key_base)

  # The cookie value a browser would send back for `id` signed by the endpoint.
  defp signed_cookie(id, key \\ nil) do
    conn =
      Plug.Test.conn("GET", "/")
      |> Map.put(:secret_key_base, key || secret())
      |> Plug.Conn.put_resp_cookie(ShopSession.cookie_name(), id, sign: true)

    conn.resp_cookies[ShopSession.cookie_name()].value
  end

  # `PhoenixKit.Config.get_parent_endpoint/0` finds the endpoint through this.
  defp with_parent_endpoint do
    previous = Application.get_env(:phoenix_kit, :parent_module)
    Application.put_env(:phoenix_kit, :parent_module, PhoenixKitEcommerce.Test)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :parent_module, previous),
        else: Application.delete_env(:phoenix_kit, :parent_module)
    end)
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

    test "never raises, whatever the context holds", ctx do
      cart = guest_cart!([{ctx.p1, 1}])
      id = cart.session_id

      for junk <- [
            %{user_uuid: "not-a-uuid", shop_session_id: id},
            %{user_uuid: 5, shop_session_id: id},
            %{user_uuid: %{}, session: %{"shop_session_id" => id}},
            %{user_uuid: nil, session: "x"},
            %{user_uuid: nil, session: [1, 2]},
            %{user_uuid: nil, session: %{"shop_session_id" => %{}}},
            %{user_uuid: nil, session: %{"shop_session_id" => 5}},
            %{user_uuid: nil, cookies: "x"},
            %{user_uuid: nil, cookies: %{"shop_session_id" => 5}},
            %{user_uuid: nil, cookies: [{"shop_session_id", id}]},
            %{"user_uuid" => %{"a" => 1}, "session" => %{}},
            %{__struct__: nil}
          ] do
        assert Shop.handoff_snapshot(junk) == nil, "#{inspect(junk)} must answer nil"
      end
    end
  end

  describe "handoff_snapshot/1 with core's context" do
    # Core hands over the session of the request (string keys) and the raw
    # cookies. The shop plug mirrors the id into the session.
    test "the guest's cart is found through the session's shop_session_id", ctx do
      cart = guest_cart!([{ctx.p1, 2}])
      context = core_snapshot_context(session: %{"shop_session_id" => cart.session_id})

      assert Shop.handoff_snapshot(context) == %{"cart_uuid" => cart.uuid}
    end

    test "a signed-in account carries nothing", ctx do
      user = fixture_user()
      cart = guest_cart!([{ctx.p1, 1}])

      context =
        core_snapshot_context(
          user_uuid: user.uuid,
          session: %{"shop_session_id" => cart.session_id}
        )

      assert Shop.handoff_snapshot(context) == nil
    end

    test "no shop session in the session: nothing to carry" do
      assert Shop.handoff_snapshot(core_snapshot_context()) == nil
      assert Shop.handoff_snapshot(core_snapshot_context(session: %{"other" => "x"})) == nil
    end

    test "an UNSIGNED cookie value is never an identity", ctx do
      with_parent_endpoint()
      cart = guest_cart!([{ctx.p1, 1}])

      context = core_snapshot_context(cookies: %{"shop_session_id" => cart.session_id})

      assert Shop.handoff_snapshot(context) == nil
    end

    test "a cookie signed under another key is not an identity either", ctx do
      with_parent_endpoint()
      cart = guest_cart!([{ctx.p1, 1}])
      forged = signed_cookie(cart.session_id, String.duplicate("x", 64))

      assert Shop.handoff_snapshot(core_snapshot_context(cookies: %{"shop_session_id" => forged})) ==
               nil
    end

    test "a cookie that verifies is read, when the session holds nothing yet", ctx do
      with_parent_endpoint()
      cart = guest_cart!([{ctx.p1, 1}])
      cookie = signed_cookie(cart.session_id)

      assert Shop.handoff_snapshot(core_snapshot_context(cookies: %{"shop_session_id" => cookie})) ==
               %{"cart_uuid" => cart.uuid}
    end

    test "an API session in the session is not a browser", ctx do
      {:ok, api} = Shop.create_cart(session_id: "api:" <> String.duplicate("c", 20))
      fill!(api, [{ctx.p1, 1}])

      context = core_snapshot_context(session: %{"shop_session_id" => api.session_id})

      assert Shop.handoff_snapshot(context) == nil
    end

    test "it reads only: nothing is written", ctx do
      cart = guest_cart!([{ctx.p1, 1}])
      before = stored(cart.uuid)

      _ =
        Shop.handoff_snapshot(
          core_snapshot_context(session: %{"shop_session_id" => cart.session_id})
        )

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

    test "a currency the shop does not price in: nothing moves, the guest's cart stays whole",
         ctx do
      source = guest_cart!([{ctx.p1, 1}, {ctx.p2, 2}])
      before = stored(source.uuid)
      carts_before = cart_count()

      assert {:ok, %{moved: 0, skipped: skipped, notices: [notice]}} =
               Shop.handoff_apply(
                 %{user_uuid: nil, shop_session_id: session(), currency: "XXX"},
                 payload(source)
               )

      assert Enum.sort(Enum.map(skipped, & &1.product_uuid)) ==
               Enum.sort([ctx.p1.uuid, ctx.p2.uuid])

      assert Enum.all?(skipped, &(&1.reason == :currency_unavailable))
      assert is_binary(notice)
      assert stored(source.uuid) == before
      assert cart_count() == carts_before
    end

    test "the report is a plain map without cookies when nothing was moved", ctx do
      source = guest_cart!([{ctx.p1, 1}])

      assert {:ok, report} =
               Shop.handoff_apply(
                 core_apply_context(currency: "XXX"),
                 payload(source)
               )

      refute Map.has_key?(report, :cookies)
    end
  end

  describe "handoff_apply/2 with core's context" do
    # A guest arriving on the target for the first time has no shop session
    # there: the hook mints an id as the shop plug does and asks core to set
    # it. A guest who has one keeps it and gets no cookie.
    test "a first visit gets a fresh session id, the cart under it, and the cookie to carry it",
         ctx do
      source = guest_cart!([{ctx.p1, 3}, {ctx.p2, 1}])

      assert {:ok, %{moved: 2, skipped: [], cookies: [{name, id, opts}]}} =
               Shop.handoff_apply(core_apply_context(currency: "EUR"), payload(source))

      assert name == "shop_session_id"
      assert is_binary(id) and byte_size(id) == 43
      assert opts == ShopSession.cookie_options(true)

      assert Keyword.take(opts, [:max_age, :http_only, :same_site, :secure, :sign]) == [
               max_age: 60 * 60 * 24 * 30,
               http_only: true,
               same_site: "Lax",
               secure: true,
               sign: true
             ]

      assert [target] = active_carts_of(id)
      assert quantities(target) == %{ctx.p1.uuid => 3, ctx.p2.uuid => 1}
      assert target.currency == "EUR"
    end

    test "the cookie core would set is what the shop plug reads back, and finds the cart", ctx do
      source = guest_cart!([{ctx.p1, 2}])

      assert {:ok, %{cookies: [_ | _] = cookies}} =
               Shop.handoff_apply(core_apply_context(), payload(source))

      # Core sets the cookies with `Plug.Conn.put_resp_cookie/4` and the options
      # it lets through (`:max_age, :http_only, :same_site, :secure, :sign, ...`).
      whitelist = [:max_age, :http_only, :same_site, :secure, :sign, :encrypt, :path]

      response =
        Enum.reduce(
          cookies,
          Plug.Test.conn("GET", "/") |> Map.put(:secret_key_base, secret()),
          fn {name, value, opts}, conn ->
            Plug.Conn.put_resp_cookie(conn, name, value, Keyword.take(opts, whitelist))
          end
        )

      %{value: sent, http_only: true, same_site: "Lax", secure: true} =
        response.resp_cookies["shop_session_id"]

      # The target browser's next request.
      request =
        Plug.Test.conn("GET", "/cart")
        |> Map.put(:secret_key_base, secret())
        |> Plug.Test.init_test_session(%{})
        |> Plug.Test.put_req_cookie("shop_session_id", sent)
        |> ShopSession.call([])

      session_id = Plug.Conn.get_session(request, "shop_session_id")
      assert [{_, ^session_id, _}] = cookies

      assert %Cart{} = cart = Shop.find_active_cart(session_id: session_id)
      assert quantities(cart) == %{ctx.p1.uuid => 2}
      # and no second identity was minted for it
      refute Map.has_key?(request.resp_cookies, "shop_session_id")
    end

    test "a target that already has a shop session keeps it and gets no cookie", ctx do
      source = guest_cart!([{ctx.p1, 2}])
      target_session = session()
      existing = "USD" |> cart_in(session_id: target_session) |> fill!([{ctx.p2, 1}])

      assert {:ok, report} =
               Shop.handoff_apply(
                 core_apply_context(session: %{"shop_session_id" => target_session}),
                 payload(source)
               )

      assert %{moved: 1, skipped: []} = report
      refute Map.has_key?(report, :cookies)
      assert quantities(existing) == %{ctx.p1.uuid => 2, ctx.p2.uuid => 1}
      assert [_only] = active_carts_of(target_session)
    end

    test "a verified signed cookie is the identity when the session holds none yet", ctx do
      with_parent_endpoint()
      source = guest_cart!([{ctx.p1, 2}])
      target_session = session()
      existing = "USD" |> cart_in(session_id: target_session) |> fill!([{ctx.p2, 1}])
      cookie = signed_cookie(target_session)

      assert {:ok, report} =
               Shop.handoff_apply(
                 core_apply_context(cookies: %{"shop_session_id" => cookie}),
                 payload(source)
               )

      refute Map.has_key?(report, :cookies)
      assert quantities(existing) == %{ctx.p1.uuid => 2, ctx.p2.uuid => 1}
    end

    # The cookie names somebody else's session. Believed, the guest's lines
    # would be added to that visitor's cart.
    test "an unsigned or forged cookie is not trusted: the guest gets a new identity", ctx do
      with_parent_endpoint()

      for forgery <- [:unsigned, :signed_under_another_key] do
        victim_session = session()
        victim = "USD" |> cart_in(session_id: victim_session) |> fill!([{ctx.p2, 1}])
        source = guest_cart!([{ctx.p1, 2}])

        cookie =
          case forgery do
            :unsigned -> victim_session
            :signed_under_another_key -> signed_cookie(victim_session, String.duplicate("x", 64))
          end

        log =
          capture_log(fn ->
            assert {:ok, %{moved: 1, cookies: [{_, id, _}]}} =
                     Shop.handoff_apply(
                       core_apply_context(cookies: %{"shop_session_id" => cookie}),
                       payload(source)
                     )

            assert id != victim_session
          end)

        assert quantities(victim) == %{ctx.p2.uuid => 1}
        # the secret is findable: this is a cookie that does not verify, not a
        # secret that is missing
        refute log =~ "cannot be verified"
      end
    end

    # With the secret unavailable even a genuine cookie reads as "no cookie",
    # and a fresh identity minted then would overwrite the browser's own.
    test "a cookie that cannot be verified because the secret is missing: nothing is minted",
         ctx do
      source = guest_cart!([{ctx.p1, 2}])
      browser_session = session()
      own = "USD" |> cart_in(session_id: browser_session) |> fill!([{ctx.p2, 1}])
      cookie = signed_cookie(browser_session)
      before = {stored(source.uuid), stored(own.uuid), cart_count()}

      log =
        capture_log(fn ->
          assert {:ok, nothing()} ==
                   Shop.handoff_apply(
                     core_apply_context(cookies: %{"shop_session_id" => cookie}),
                     payload(source)
                   )
        end)

      assert {stored(source.uuid), stored(own.uuid), cart_count()} == before
      assert [_one_warning, _after] = String.split(log, "[warning]")
      assert log =~ "secret_key_base"
      refute log =~ cookie
      refute log =~ browser_session
      refute log =~ source.uuid
    end

    test "with the secret missing, an identity the session names is still used", ctx do
      source = guest_cart!([{ctx.p1, 2}])
      browser_session = session()
      own = "USD" |> cart_in(session_id: browser_session) |> fill!([{ctx.p2, 1}])

      context =
        core_apply_context(
          session: %{"shop_session_id" => browser_session},
          cookies: %{"shop_session_id" => signed_cookie(browser_session)}
        )

      log =
        capture_log(fn ->
          assert {:ok, %{moved: 1} = report} = Shop.handoff_apply(context, payload(source))
          refute Map.has_key?(report, :cookies)
        end)

      refute log =~ "cannot be verified"
      assert quantities(own) == %{ctx.p1.uuid => 2, ctx.p2.uuid => 1}
    end

    test "with the secret missing and no cookie, there is nothing to overwrite", ctx do
      source = guest_cart!([{ctx.p1, 1}])

      log =
        capture_log(fn ->
          assert {:ok, %{moved: 1, cookies: [{"shop_session_id", _, _}]}} =
                   Shop.handoff_apply(core_apply_context(), payload(source))
        end)

      refute log =~ "cannot be verified"
    end

    test "a cookie is set only when something was moved into the new identity", ctx do
      source = guest_cart!([{ctx.p1, 1}])
      {:ok, _} = Shop.update_product(ctx.p1, %{"status" => "archived"})
      carts_before = cart_count()

      assert {:ok, report} = Shop.handoff_apply(core_apply_context(), payload(source))

      assert %{moved: 0, skipped: [_]} = report
      refute Map.has_key?(report, :cookies)
      # and no cart is left under an id nobody holds
      assert cart_count() == carts_before
    end

    test "a first visit with some lines moved keeps the cart it made, under the cookie's id",
         ctx do
      source = guest_cart!([{ctx.p1, 1}, {ctx.p2, 1}])
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})
      carts_before = cart_count()

      assert {:ok, %{moved: 1, cookies: [{_, id, _}]}} =
               Shop.handoff_apply(core_apply_context(), payload(source))

      assert cart_count() == carts_before + 1
      assert [_kept] = active_carts_of(id)
    end

    test "a cart the target session already has is never deleted, whatever moves", ctx do
      source = guest_cart!([{ctx.p1, 1}])
      {:ok, _} = Shop.update_product(ctx.p1, %{"status" => "archived"})
      target_session = session()
      empty = cart_in("USD", session_id: target_session)
      context = core_apply_context(session: %{"shop_session_id" => target_session})
      carts_before = cart_count()

      assert {:ok, %{moved: 0, skipped: [_]}} = Shop.handoff_apply(context, payload(source))

      assert cart_count() == carts_before
      assert Repo.get!(Cart, empty.uuid).status == "active"
    end

    test "a signed-in account's cart is never deleted when nothing moves", ctx do
      user = fixture_user()
      source = guest_cart!([{ctx.p1, 1}])
      {:ok, _} = Shop.update_product(ctx.p1, %{"status" => "archived"})

      assert {:ok, %{moved: 0}} =
               Shop.handoff_apply(core_apply_context(user_uuid: user.uuid), payload(source))

      assert Repo.exists?(from(c in Cart, where: c.user_uuid == ^user.uuid))
    end

    test "a signed-in account's cart is found by user, with no cookie", ctx do
      user = fixture_user()
      source = guest_cart!([{ctx.p2, 2}])
      own = "USD" |> cart_in(user_uuid: user.uuid, session_id: session()) |> fill!([{ctx.p1, 1}])

      assert {:ok, report} =
               Shop.handoff_apply(core_apply_context(user_uuid: user.uuid), payload(source))

      refute Map.has_key?(report, :cookies)
      assert quantities(own) == %{ctx.p1.uuid => 1, ctx.p2.uuid => 2}
    end
  end

  describe "handoff_apply/2 currency" do
    # The shop does not know a host's currency, and neither does core's context
    # (`:host` and `:locale` only). Core runs the hook in a task of its own,
    # without the request's process dictionary, which is where Billing keeps the
    # request's display currency. So through core the target cart is created in
    # the base currency, and the cart and checkout pages bring it into the
    # domain's currency when the shopper opens them (`redenominate_cart/2`).
    test "inside a task, as core runs it, a first visit's cart is made in the base currency",
         ctx do
      source = guest_cart!([{ctx.p1, 1}], "EUR")

      # The request process names EUR; the task does not inherit it.
      Currency.put_request_currency("EUR")
      context = core_apply_context(host: "shop.de", locale: "de")
      task = Task.async(fn -> Shop.handoff_apply(context, payload(source)) end)
      result = Task.await(task)
      Currency.put_request_currency(nil)

      assert {:ok, %{moved: 1, cookies: [{_, id, _}]}} = result
      assert [target] = active_carts_of(id)
      assert %{currency: "USD", base_currency: "USD"} = target
      assert Decimal.equal?(target.exchange_rate, Decimal.new("1"))

      assert [%{currency: "USD", unit_price: unit_price}] = reload(target).items
      assert Decimal.equal?(unit_price, Decimal.new("10.00"))
    end

    test "inside a task the target cart a guest already has keeps its own currency", ctx do
      source = guest_cart!([{ctx.p1, 1}])
      target_session = session()
      existing = "EUR" |> cart_in(session_id: target_session) |> fill!([{ctx.p2, 1}])
      context = core_apply_context(session: %{"shop_session_id" => target_session})

      assert {:ok, %{moved: 1}} =
               Task.await(Task.async(fn -> Shop.handoff_apply(context, payload(source)) end))

      cart = reload(existing)
      assert cart.currency == "EUR"
      assert Enum.all?(cart.items, &(&1.currency == "EUR"))
      assert Decimal.equal?(cart.exchange_rate, Decimal.new("0.909091"))
    end

    test "the target cart's own currency is left as it is; host and locale are not believed",
         ctx do
      source = guest_cart!([{ctx.p1, 1}])
      target_session = session()
      existing = "EUR" |> cart_in(session_id: target_session) |> fill!([{ctx.p2, 1}])

      # The host and the locale name a USD shop: neither is believed.
      context =
        core_apply_context(
          session: %{"shop_session_id" => target_session},
          host: "shop.us",
          locale: "en"
        )

      assert {:ok, %{moved: 1}} = Shop.handoff_apply(context, payload(source))

      cart = reload(existing)
      assert cart.currency == "EUR"
      assert Enum.all?(cart.items, &(&1.currency == "EUR"))
      assert Decimal.equal?(cart.exchange_rate, Decimal.new("0.909091"))
    end

    # What a caller that does know the currency says outright.
    test "an explicit :currency makes the target cart, and brings an existing one, into it",
         ctx do
      source = guest_cart!([{ctx.p1, 1}])

      assert {:ok, %{moved: 1, cookies: [{_, id, _}]}} =
               Shop.handoff_apply(core_apply_context(currency: "EUR"), payload(source))

      assert [%{currency: "EUR"}] = active_carts_of(id)

      second = guest_cart!([{ctx.p1, 1}])
      target_session = session()
      existing = "USD" |> cart_in(session_id: target_session) |> fill!([{ctx.p2, 1}])

      assert {:ok, %{moved: 1}} =
               Shop.handoff_apply(
                 %{user_uuid: nil, shop_session_id: target_session, currency: "EUR"},
                 payload(second)
               )

      assert reload(existing).currency == "EUR"
    end

    # Not the hook's doing: a new cart is made as `create_cart/1` makes it, in
    # the display currency of the process it runs in.
    test "a direct caller in a request process that names a currency gets a cart in it", ctx do
      source = guest_cart!([{ctx.p1, 1}])
      Currency.put_request_currency("EUR")

      assert {:ok, %{cookies: [{_, id, _}]}} =
               Shop.handoff_apply(core_apply_context(), payload(source))

      Currency.put_request_currency(nil)
      assert [%{currency: "EUR"}] = active_carts_of(id)
    end
  end

  describe "handoff_apply/2 notices" do
    # The count is the report's `moved`: lines of the cart, one per product and
    # option choice, whatever the quantity of each.
    test "a cart that came along says how many products, in the language of the target", ctx do
      one = guest_cart!([{ctx.p1, 3}])
      two = guest_cart!([{ctx.p1, 1}, {ctx.p2, 5}])

      assert {:ok, %{moved: 1, notices: ["Your cart came with you: 1 product."]}} =
               Shop.handoff_apply(core_apply_context(locale: "en"), payload(one))

      assert {:ok, %{moved: 2, notices: ["Your cart came with you: 2 products."]}} =
               Shop.handoff_apply(core_apply_context(locale: "en"), payload(two))
    end

    test "ru and uk use their three plural forms" do
      backend = PhoenixKitEcommerce.Gettext

      for {locale, came, forms} <- [{"ru", @ru_came, @ru_forms}, {"uk", @uk_came, @uk_forms}],
          {count, form} <- [{1, 0}, {21, 0}, {2, 1}, {3, 1}, {5, 2}, {11, 2}] do
        Gettext.with_locale(backend, locale, fn ->
          assert Gettext.dngettext(
                   backend,
                   "default",
                   "Your cart came with you: %{count} product.",
                   "Your cart came with you: %{count} products.",
                   count
                 ) == "#{came} #{count} #{elem(forms, form)}."
        end)
      end
    end

    test "translated, with the plural of the language", ctx do
      for {locale, one, many} <- [
            {"de", "Ihr Warenkorb ist mitgekommen: 1 Produkt.",
             "Ihr Warenkorb ist mitgekommen: 2 Produkte."},
            {"fr", "Votre panier vous a suivi : 1 produit.",
             "Votre panier vous a suivi : 2 produits."},
            {"et", "Teie ostukorv tuli kaasa: 1 toode.", "Teie ostukorv tuli kaasa: 2 toodet."},
            {"ru", "#{@ru_came} 1 #{elem(@ru_forms, 0)}.",
             "#{@ru_came} 2 #{elem(@ru_forms, 1)}."},
            {"uk", "#{@uk_came} 1 #{elem(@uk_forms, 0)}.", "#{@uk_came} 2 #{elem(@uk_forms, 1)}."}
          ] do
        one_cart = guest_cart!([{ctx.p1, 1}])
        two_carts = guest_cart!([{ctx.p1, 1}, {ctx.p2, 1}])

        assert {:ok, %{notices: [^one]}} =
                 Shop.handoff_apply(core_apply_context(locale: locale), payload(one_cart))

        assert {:ok, %{notices: [^many]}} =
                 Shop.handoff_apply(core_apply_context(locale: locale), payload(two_carts))
      end
    end

    test "a dialect picks the catalogue of its base language", ctx do
      source = guest_cart!([{ctx.p1, 1}])

      assert {:ok, %{notices: ["Ihr Warenkorb ist mitgekommen: 1 Produkt."]}} =
               Shop.handoff_apply(core_apply_context(locale: "de-DE"), payload(source))
    end

    test "the process locale of the request is left as it was", ctx do
      source = guest_cart!([{ctx.p1, 1}])
      before = Gettext.get_locale(PhoenixKitEcommerce.Gettext)

      assert {:ok, %{notices: [_]}} =
               Shop.handoff_apply(core_apply_context(locale: "de"), payload(source))

      assert Gettext.get_locale(PhoenixKitEcommerce.Gettext) == before
    end

    test "a skipped product is named with a short reason", ctx do
      source = guest_cart!([{ctx.p1, 1}, {ctx.p2, 2}])
      german_source = guest_cart!([{ctx.p1, 1}, {ctx.p2, 2}])
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      assert {:ok, %{moved: 1, skipped: [_], notices: [moved, left]}} =
               Shop.handoff_apply(core_apply_context(locale: "en"), payload(source))

      assert moved == "Your cart came with you: 1 product."

      assert left ==
               "These stayed in your cart on the other site: #{ctx.p2.title["en"]} (no longer available)."

      assert {:ok, %{notices: [_, german]}} =
               Shop.handoff_apply(
                 core_apply_context(locale: "de"),
                 payload(german_source)
               )

      assert german ==
               "Diese Artikel sind in Ihrem Warenkorb auf der anderen Seite geblieben: #{ctx.p2.title["en"]} (nicht mehr verfügbar)."
    end

    test "every message of the handoff is translated in every shipped language" do
      backend = PhoenixKitEcommerce.Gettext

      singles = [
        "an item",
        "no longer available",
        "not enough in stock",
        "quantity limit reached",
        "cannot be added here right now",
        "These stayed in your cart on the other site: %{products}."
      ]

      for locale <- ~w(de fr et ru uk) do
        Gettext.with_locale(backend, locale, fn ->
          for msgid <- singles do
            translated = Gettext.dgettext(backend, "default", msgid, products: "P")

            refute translated == String.replace(msgid, "%{products}", "P"),
                   "#{locale}: #{inspect(msgid)} is not translated"
          end

          for count <- [1, 2, 5] do
            translated =
              Gettext.dngettext(
                backend,
                "default",
                "Your cart came with you: %{count} product.",
                "Your cart came with you: %{count} products.",
                count
              )

            refute translated =~ "Your cart came with you",
                   "#{locale}: the plural is not translated"
          end
        end)
      end
    end

    test "nothing to say, nothing said", ctx do
      source = guest_cart!([{ctx.p1, 1}])
      context = core_apply_context()

      assert {:ok, %{moved: 1}} = Shop.handoff_apply(context, payload(source))
      # applied again: the source is merged, nothing moves, no notice, no cookie
      assert {:ok, nothing()} == Shop.handoff_apply(context, payload(source))
    end
  end

  describe "handoff_apply/2 keeps what it cannot move" do
    test "a skipped line stays in the guest's cart, which stays active", ctx do
      source = guest_cart!([{ctx.p1, 1}, {ctx.p2, 2}])
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      assert {:ok, %{moved: 1, skipped: [skipped]}} =
               Shop.handoff_apply(core_apply_context(), payload(source))

      assert skipped.product_uuid == ctx.p2.uuid

      row = Repo.get!(Cart, source.uuid)
      assert row.status == "active"
      assert [left] = Repo.all(from(i in CartItem, where: i.cart_uuid == ^source.uuid))
      assert left.product_uuid == ctx.p2.uuid and left.quantity == 2
      assert row.items_count == 2
    end

    test "what stayed can be carried by the next handoff, which then merges the cart", ctx do
      source = guest_cart!([{ctx.p1, 1}, {ctx.p2, 2}])
      {:ok, p2} = Shop.update_product(ctx.p2, %{"status" => "archived"})
      target_session = session()
      context = core_apply_context(session: %{"shop_session_id" => target_session})

      assert {:ok, %{moved: 1}} = Shop.handoff_apply(context, payload(source))
      {:ok, _} = Shop.update_product(p2, %{"status" => "active"})
      assert {:ok, %{moved: 1, skipped: []}} = Shop.handoff_apply(context, payload(source))

      assert Repo.get!(Cart, source.uuid).status == "merged"

      assert quantities(hd(active_carts_of(target_session))) ==
               %{ctx.p1.uuid => 1, ctx.p2.uuid => 2}
    end

    test "a source that gained a user between the read and the lock is not adopted", ctx do
      user = fixture_user()
      source = guest_cart!([{ctx.p1, 1}])
      before_items = stored(source.uuid) |> elem(1)

      # The payload's cart is read first; the user arrives before it is locked.
      after_first_query("SELECT", "phoenix_kit_shop_carts", fn ->
        Repo.update_all(from(c in Cart, where: c.uuid == ^source.uuid),
          set: [user_uuid: user.uuid]
        )
      end)

      carts_before = cart_count()

      assert {:ok, report} = Shop.handoff_apply(core_apply_context(), payload(source))

      assert report.moved == 0
      assert cart_count() == carts_before
      row = Repo.get!(Cart, source.uuid)
      assert row.status == "active"
      assert row.user_uuid == user.uuid
      assert stored(source.uuid) |> elem(1) == before_items
    end
  end

  describe "handoff_apply/2 never raises" do
    test "a context that names no usable account is a quiet no-op, whatever the payload", ctx do
      source = guest_cart!([{ctx.p1, 1}])
      before = {stored(source.uuid), cart_count()}

      contexts = [
        nil,
        "x",
        5,
        [],
        %{user_uuid: "not-a-uuid", session: %{}},
        %{user_uuid: 5},
        %{user_uuid: %{}},
        %{"user_uuid" => "zzz", "shop_session_id" => session()}
      ]

      payloads = [nil, %{}, "x", 5, [], payload(source), %{"cart_uuid" => "not-a-uuid"}]

      for context <- contexts, pay <- payloads do
        assert {:ok, %{moved: 0, skipped: []}} = Shop.handoff_apply(context, pay),
               "#{inspect(context)} / #{inspect(pay)}"
      end

      assert {stored(source.uuid), cart_count()} == before
    end

    test "junk in the session, the cookies, the locale or the currency is ignored", ctx do
      contexts = [
        %{user_uuid: nil, session: "x", cookies: 5},
        %{user_uuid: nil, session: %{"shop_session_id" => %{}}, cookies: [1]},
        %{user_uuid: nil, session: [1], cookies: %{"shop_session_id" => 5}},
        %{user_uuid: nil, shop_session_id: %{}, currency: %{}, locale: 5, language: []},
        %{user_uuid: nil, shop_session_id: "api:" <> String.duplicate("d", 20)}
      ]

      for context <- contexts do
        source = guest_cart!([{ctx.p1, 1}])

        assert {:ok, %{moved: 1, skipped: []}} = Shop.handoff_apply(context, payload(source)),
               inspect(context)
      end
    end

    test "a locale or language that is not text is ignored", ctx do
      source = guest_cart!([{ctx.p1, 1}])

      assert {:ok, %{moved: 1}} =
               Shop.handoff_apply(core_apply_context(locale: 5, language: %{}), payload(source))
    end

    test "an eligible cart that cannot be carried is reported, kept whole, and no error", ctx do
      source = guest_cart!([{ctx.p1, 2}])
      before = stored(source.uuid)

      for currency <- ["XXX", "eur "] do
        assert {:ok, %{moved: 0, skipped: [%{reason: :currency_unavailable}]}} =
                 Shop.handoff_apply(core_apply_context(currency: currency), payload(source))
      end

      assert stored(source.uuid) == before
    end

    test "a deadlock the database resolves against it is a report, not an error", ctx do
      source = guest_cart!([{ctx.p1, 1}])
      before = stored(source.uuid)

      Repo.query!("""
      CREATE FUNCTION pk_test_raise_deadlock() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'simulated deadlock' USING ERRCODE = '40P01'; END
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER pk_test_raise_deadlock BEFORE INSERT ON phoenix_kit_shop_cart_items
      FOR EACH ROW EXECUTE FUNCTION pk_test_raise_deadlock()
      """)

      carts_before = cart_count()

      assert {:ok, %{moved: 0, skipped: [%{reason: :busy}]} = report} =
               Shop.handoff_apply(core_apply_context(), payload(source))

      refute Map.has_key?(report, :cookies)
      assert stored(source.uuid) == before
      assert cart_count() == carts_before
    end
  end

  describe "a failure inside a hook" do
    # What is logged: where it happened (the exception's module and the top
    # frame of the shop's own code: module, function/arity, line), never a
    # message, an argument or a payload value.
    @frame ~r/failed: Postgrex\.Error at PhoenixKitEcommerce[\w.]*\.\S+\/\d+ \(line \d+\)/

    test "handoff_apply/2 answers a no-op and names the exception and the shop's top frame",
         ctx do
      source = guest_cart!([{ctx.p1, 1}])

      Repo.query!("""
      CREATE FUNCTION pk_test_raise_on_cart() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'marker-4711 %', NEW.session_id USING ERRCODE = 'XX000'; END
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER pk_test_raise_on_cart BEFORE INSERT ON phoenix_kit_shop_carts
      FOR EACH ROW EXECUTE FUNCTION pk_test_raise_on_cart()
      """)

      log =
        capture_log(fn ->
          assert {:ok, nothing()} == Shop.handoff_apply(core_apply_context(), payload(source))
        end)

      assert log =~ "[Shop] handoff_apply failed: Postgrex.Error at "
      assert log =~ @frame
      refute log =~ "marker-4711"
      refute log =~ source.uuid
    end

    test "handoff_snapshot/1 answers nil and names the exception and the shop's top frame" do
      session_id = session()
      Repo.query!("ALTER TABLE phoenix_kit_shop_carts RENAME TO pk_test_carts_gone")

      log =
        capture_log(fn ->
          assert Shop.handoff_snapshot(%{user_uuid: nil, shop_session_id: session_id}) == nil
        end)

      assert log =~ "[Shop] handoff_snapshot failed: Postgrex.Error at "
      assert log =~ @frame
      refute log =~ "pk_test_carts_gone"
      refute log =~ session_id
    end
  end

  describe "handoff_apply/2 and the operators' notifications" do
    test "the lines are moved with via: :assistant: no per-line notification", ctx do
      PhoenixKit.Settings.update_setting_with_module("shop_notify_cart_item", "true", "shop")
      _owner = fixture_user()
      source = guest_cart!([{ctx.p1, 1}, {ctx.p2, 1}])
      before = count_notifications("shop.cart_item_added")

      assert {:ok, %{moved: 2}} = Shop.handoff_apply(core_apply_context(), payload(source))

      assert count_notifications("shop.cart_item_added") == before
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

    # Core calls `handoff_apply/2` only for a payload that has an entry for the
    # module, and `handoff_snapshot/1` is nil for an account, so an account never
    # arrives here without one: with none, nothing is done, whatever the cart is.
    test "no payload: the user's own cart is left as it is", ctx do
      user = fixture_user()
      own = "USD" |> cart_in(user_uuid: user.uuid, session_id: session()) |> fill!([{ctx.p1, 3}])
      before = {stored(own.uuid), cart_count()}

      assert {:ok, nothing()} ==
               Shop.handoff_apply(
                 %{user_uuid: user.uuid, shop_session_id: session(), currency: "EUR"},
                 nil
               )

      assert {stored(own.uuid), cart_count()} == before
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

    test "anything that is not a context is a quiet no-op, and the cart stays", %{p1: p1} do
      cart = guest_cart!([{p1, 1}])
      before = {stored(cart.uuid), cart_count()}

      for junk <- [nil, "x", 5, [], [cart.uuid]] do
        assert {:ok, nothing()} == Shop.handoff_apply(junk, payload(cart))
      end

      assert {stored(cart.uuid), cart_count()} == before
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
