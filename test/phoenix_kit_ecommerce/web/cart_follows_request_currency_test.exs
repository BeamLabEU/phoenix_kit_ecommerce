defmodule PhoenixKitEcommerce.Web.CartFollowsRequestCurrencyTest do
  @moduledoc """
  A signed-in shopper's active cart is found by user on every domain, and each
  domain has its own display currency. The cart page and the checkout page
  bring the cart into the REQUEST's currency when they mount
  (`PhoenixKitEcommerce.redenominate_cart/2`), because a cart is paid in the
  currency of the site it is paid on. A cart already in the request's currency
  is left alone: its rate stays frozen (§4.4).

  An OPEN page is another matter: it follows the cart, whatever currency the
  cart is in (another tab or domain may have re-denominated it and broadcast
  the new cart), and never re-denominates on a broadcast. Only a mount does.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Web.Helpers

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    Repo.delete_all(Currency)

    {:ok, _usd} =
      Billing.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, eur} =
      Billing.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Currency Vase"},
        "price" => Decimal.new("138.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false,
        "weight_grams" => 0
      })

    user = PhoenixKitEcommerce.DataCase.fixture_user()
    %{eur: eur, product: product, user: user}
  end

  # The signed-in shopper's cart, frozen in `code` by creating it under that
  # request currency, and the conn that opens the pages on a domain whose
  # display currency is `request_code`.
  defp user_cart(user, product, code) do
    Currency.put_request_currency(code)
    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    Currency.put_request_currency(nil)
    cart
  end

  defp conn_for(conn, user, request_code) do
    Plug.Test.init_test_session(conn, %{
      "phoenix_kit_test_scope" => fake_scope(user_uuid: user.uuid, email: user.email),
      "phoenix_kit_test_currency" => request_code,
      "shop_session_id" => "follows-#{System.unique_integer([:positive])}"
    })
  end

  defp stored(cart_uuid) do
    {Repo.get!(Cart, cart_uuid),
     Repo.all(from(i in CartItem, where: i.cart_uuid == ^cart_uuid, order_by: i.uuid))}
  end

  # What the shopper is charged and in what currency. The checkout page also
  # writes other things of its own on mount (the payment option), so its tests
  # compare this rather than the whole row.
  defp money(cart_uuid) do
    {row, lines} = stored(cart_uuid)

    {{row.currency, row.base_currency, row.exchange_rate, row.subtotal, row.total},
     Enum.map(lines, &{&1.currency, &1.unit_price, &1.base_unit_price, &1.compare_at_price})}
  end

  defp total_text(view, id), do: view |> element(id) |> render()

  describe "cart page" do
    test "a USD cart opened on the EUR domain is shown and stored in EUR",
         %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")
      assert cart.currency == "USD"

      {:ok, view, _html} = live(conn_for(conn, user, "EUR"), "/cart")

      total = total_text(view, "#cart-summary-total")
      assert total =~ "€"
      assert total =~ "125.45"
      refute total =~ "$"

      {row, [line]} = stored(cart.uuid)
      assert row.currency == "EUR"
      assert Decimal.equal?(row.total, Decimal.new("125.45"))
      assert line.currency == "EUR"
      assert Decimal.equal?(line.base_unit_price, Decimal.new("138.00"))
    end

    test "and back: the same cart opened on the USD domain is USD again, exactly",
         %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")

      {:ok, _view, _html} = live(conn_for(conn, user, "EUR"), "/cart")
      assert Repo.get!(Cart, cart.uuid).currency == "EUR"

      {:ok, view, _html} = live(conn_for(conn, user, "USD"), "/cart")

      total = total_text(view, "#cart-summary-total")
      assert total =~ "$"
      assert total =~ "138.00"
      assert Decimal.equal?(Repo.get!(Cart, cart.uuid).total, Decimal.new("138.00"))
    end

    test "a cart already in the request currency keeps its frozen rate and is not written",
         %{conn: conn, user: user, product: product, eur: eur} do
      cart = user_cart(user, product, "EUR")
      {:ok, _} = Billing.update_currency(eur, %{exchange_rate: "0.95"})
      before = stored(cart.uuid)

      {:ok, view, _html} = live(conn_for(conn, user, "EUR"), "/cart")

      assert total_text(view, "#cart-summary-total") =~ "125.45"
      assert stored(cart.uuid) == before
    end

    test "an EMPTY cart in the wrong currency is brought over too",
         %{conn: conn, user: user} do
      Currency.put_request_currency("USD")
      {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
      Currency.put_request_currency(nil)
      assert cart.currency == "USD"

      {:ok, _view, _html} = live(conn_for(conn, user, "EUR"), "/cart")

      row = Repo.get!(Cart, cart.uuid)
      assert row.currency == "EUR"
      assert Decimal.equal?(row.exchange_rate, Decimal.new("0.909091"))
    end

    test "when it cannot be done the cart is shown as it is, without a notice, and the page lives",
         %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")
      [line] = cart.items

      Repo.update_all(from(i in CartItem, where: i.uuid == ^line.uuid),
        set: [base_unit_price: nil]
      )

      before = stored(cart.uuid)

      {:ok, view, _html} = live(conn_for(conn, user, "EUR"), "/cart")

      refute has_element?(view, "#test-flash-error")
      assert total_text(view, "#cart-summary-total") =~ "$"
      assert stored(cart.uuid) == before
    end

    # The page never even finds a cart that is being paid (`find_active_cart`
    # skips it), so this does not reach the `:cart_not_active` guard of
    # `redenominate_cart/2`; the helper test below does. What the page does is
    # pinned here.
    test "a cart that is being paid is not shown and not touched; the shopper gets a new one",
         %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")

      Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: "converting"])
      before = stored(cart.uuid)

      {:ok, _view, _html} = live(conn_for(conn, user, "EUR"), "/cart")

      # The page started the shopper a new cart, in the domain's currency.
      assert stored(cart.uuid) == before

      assert %Cart{currency: "EUR"} =
               Repo.one!(
                 from(c in Cart, where: c.user_uuid == ^user.uuid and c.status == "active")
               )
    end
  end

  describe "checkout page" do
    test "a USD cart opened on the EUR domain is shown and stored in EUR",
         %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")

      {:ok, view, _html} = live(conn_for(conn, user, "EUR"), "/checkout")

      total = total_text(view, "#checkout-summary-total")
      assert total =~ "€"
      assert total =~ "125.45"

      {row, [line]} = stored(cart.uuid)
      assert row.currency == "EUR"
      assert line.currency == "EUR"
    end

    test "a cart already in the request currency keeps its frozen rate and is not written",
         %{conn: conn, user: user, product: product, eur: eur} do
      cart = user_cart(user, product, "EUR")
      {:ok, _} = Billing.update_currency(eur, %{exchange_rate: "0.95"})
      before = money(cart.uuid)

      {:ok, _view, _html} = live(conn_for(conn, user, "EUR"), "/checkout")

      assert money(cart.uuid) == before
    end

    test "when it cannot be done the cart is shown as it is, without a notice, and the page lives",
         %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")
      [line] = cart.items

      Repo.update_all(from(i in CartItem, where: i.uuid == ^line.uuid),
        set: [base_unit_price: nil]
      )

      before = money(cart.uuid)

      {:ok, view, _html} = live(conn_for(conn, user, "EUR"), "/checkout")

      refute has_element?(view, "#test-flash-error")
      assert total_text(view, "#checkout-summary-total") =~ "$"
      assert money(cart.uuid) == before
    end

    # As on the cart page: `find_active_cart` never returns this cart, so the
    # guard in `redenominate_cart/2` is reached by the helper test below.
    test "a cart that is being paid is not shown and not touched",
         %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")

      Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: "converting"])
      before = money(cart.uuid)

      # No active cart: the page sends the shopper back to the cart page.
      assert {:error, {:live_redirect, _}} = live(conn_for(conn, user, "EUR"), "/checkout")
      assert money(cart.uuid) == before
    end
  end

  describe "the helper both pages call" do
    # A socket that can carry a flash, without a LiveView process.
    defp flash_socket, do: %Phoenix.LiveView.Socket{assigns: %{flash: %{}, __changed__: %{}}}

    test "a currency that is not available says so to the shopper, and leaves the cart",
         %{user: user, product: product} do
      cart = user_cart(user, product, "USD")
      Currency.put_request_currency("EUR")

      # A cart frozen in a currency that has no row: the base-change path cannot
      # price it.
      Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid),
        set: [currency: "XXX", base_currency: "EUR"]
      )

      cart = Shop.get_cart(cart.uuid)
      before = stored(cart.uuid)

      log =
        capture_log(fn ->
          assert {socket, ^cart} = Helpers.cart_in_request_currency(flash_socket(), cart)

          assert socket.assigns.flash == %{
                   "error" => PhoenixKitEcommerce.Errors.message(:currency_unavailable)
                 }
        end)

      assert log =~ ":currency_unavailable"
      assert stored(cart.uuid) == before
    end

    test "any other reason shows the shopper nothing new, leaves the cart, and logs once",
         %{user: user, product: product} do
      cart = user_cart(user, product, "USD")
      [line] = cart.items
      Currency.put_request_currency("EUR")

      Repo.update_all(from(i in CartItem, where: i.uuid == ^line.uuid),
        set: [base_unit_price: nil]
      )

      before = stored(cart.uuid)
      socket = flash_socket()

      log =
        capture_log(fn ->
          assert {^socket, ^cart} = Helpers.cart_in_request_currency(socket, cart)
        end)

      assert log =~ ":no_base_price"
      assert length(String.split(log, "could not be brought into the request currency")) == 2
      assert stored(cart.uuid) == before
    end

    test "a cart that stopped being active under it is returned as it is, silently, and not touched",
         %{user: user, product: product} do
      cart = user_cart(user, product, "USD")
      Currency.put_request_currency("EUR")

      # What the page holds says "active"; the row says it is being paid.
      Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: "converting"])
      before = stored(cart.uuid)
      socket = %Phoenix.LiveView.Socket{}

      assert {^socket, ^cart} =
               Helpers.cart_in_request_currency(socket, cart)

      assert stored(cart.uuid) == before
    end
  end

  describe "an open cart page when the cart changes currency under it" do
    setup %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")
      {:ok, view, _html} = live(conn_for(conn, user, "USD"), "/cart")
      assert total_text(view, "#cart-summary-total") =~ "$"
      %{cart: cart, view: view}
    end

    test "shows the cart as the cart row is: the new symbol and the new amounts",
         %{cart: cart, view: view} do
      {:ok, _} = Shop.redenominate_cart(Shop.get_cart(cart.uuid), "EUR")

      total = total_text(view, "#cart-summary-total")
      assert total =~ "€"
      assert total =~ "125.45"
      refute total =~ "$"
    end

    test "and does not move the cart back to its own request's currency",
         %{cart: cart, view: view} do
      {:ok, _} = Shop.redenominate_cart(Shop.get_cart(cart.uuid), "EUR")
      _ = render(view)

      # The page's request currency is still USD; the cart stays what it was
      # made, on every broadcast it handled.
      row = Repo.get!(Cart, cart.uuid)
      assert row.currency == "EUR"
      assert Decimal.equal?(row.total, Decimal.new("125.45"))
    end

    test "takes the currency of a cart it is handed through the payment event too",
         %{cart: cart, view: view} do
      {:ok, eur} = Shop.redenominate_cart(Shop.get_cart(cart.uuid), "EUR")
      {:ok, _usd} = Shop.redenominate_cart(eur, "USD")
      assert total_text(view, "#cart-summary-total") =~ "$"

      send(view.pid, {:payment_selected, eur})
      assert total_text(view, "#cart-summary-total") =~ "€"
    end
  end

  describe "an open checkout page when the cart changes currency under it" do
    setup %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")
      {:ok, view, _html} = live(conn_for(conn, user, "USD"), "/checkout")
      assert total_text(view, "#checkout-summary-total") =~ "$"
      %{cart: cart, view: view}
    end

    test "shows the new symbol and the new amounts, not new amounts under the old symbol",
         %{cart: cart, view: view} do
      {:ok, _} = Shop.redenominate_cart(Shop.get_cart(cart.uuid), "EUR")

      total = total_text(view, "#checkout-summary-total")
      assert total =~ "€"
      assert total =~ "125.45"
      refute total =~ "$"
      assert Repo.get!(Cart, cart.uuid).currency == "EUR"
    end

    test "takes the currency of a cart it is handed through the payment event too",
         %{cart: cart, view: view} do
      {:ok, eur} = Shop.redenominate_cart(Shop.get_cart(cart.uuid), "EUR")
      {:ok, _usd} = Shop.redenominate_cart(eur, "USD")
      assert total_text(view, "#checkout-summary-total") =~ "$"

      send(view.pid, {:payment_selected, eur})

      assert total_text(view, "#checkout-summary-total") =~ "€"
    end

    test "confirming places the order in the currency and at the totals the page showed",
         %{conn: conn, user: user, cart: cart, view: view} do
      _ = conn
      billing = complete_billing("EE", "follows-currency")
      view |> form("#checkout-billing-form", billing: billing) |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()
      assert total_text(view, "#checkout-summary-total") =~ "138.00"

      {:ok, _} = Shop.redenominate_cart(Shop.get_cart(cart.uuid), "EUR")

      shown = total_text(view, "#checkout-summary-total")
      assert shown =~ "€"
      assert shown =~ "125.45"

      view |> element("#checkout-confirm-order") |> render_click()
      {path, _flash} = assert_redirect(view)

      assert [order] = Billing.list_user_orders(user.uuid)
      assert path =~ "/checkout/complete/#{order.uuid}"
      assert order.currency == "EUR"
      assert Decimal.equal?(order.total, Decimal.new("125.45"))
    end
  end

  describe "an open checkout page and the rate drift notice" do
    test "follows the cart it shows",
         %{conn: conn, user: user, eur: eur, product: product} do
      Currency.put_request_currency("EUR")
      {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
      Currency.put_request_currency(nil)
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      assert cart.currency == "EUR"
      # Past the alert threshold, in EUR: the cart opened on the EUR domain
      # shows the notice.
      {:ok, _} = Billing.update_currency(eur, %{exchange_rate: "0.96"})
      stale_eur = Shop.get_cart(cart.uuid)

      {:ok, view, _html} = live(conn_for(conn, user, "EUR"), "/checkout")
      assert has_element?(view, "#checkout-fx-drift")

      {:ok, _usd} = Shop.redenominate_cart(Shop.get_cart(cart.uuid), "USD")
      refute has_element?(view, "#checkout-fx-drift")

      send(view.pid, {:payment_selected, stale_eur})
      assert has_element?(view, "#checkout-fx-drift")
    end
  end

  describe "the shipping options of an open page" do
    setup %{user: user} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Currency Parcel"},
          "price" => Decimal.new("138.00"),
          "status" => "active",
          "currency" => "USD",
          "product_type" => "physical",
          "requires_shipping" => true,
          "weight_grams" => 300
        })

      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Flat #{System.unique_integer([:positive])}",
          "price" => Decimal.new("10.00"),
          "active" => true
        })

      %{cart: user_cart(user, product, "USD"), method: method}
    end

    test "on the cart page the method's price follows the cart's currency",
         %{conn: conn, user: user, cart: cart, method: method} do
      PhoenixKit.Settings.update_setting_with_module(
        "shop_shipping_selection_position",
        "cart",
        "shop"
      )

      {:ok, view, _html} = live(conn_for(conn, user, "USD"), "/cart")
      price = "#cart-shipping-price-#{method.uuid}"
      assert total_text(view, price) =~ "$10.00"

      {:ok, _} = Shop.redenominate_cart(Shop.get_cart(cart.uuid), "EUR")

      assert total_text(view, price) =~ "€9.09"
      assert total_text(view, "#cart-summary-shipping") =~ "€9.09"
    end

    test "on the checkout shipping step the method's price follows the cart's currency",
         %{conn: conn, user: user, cart: cart, method: method} do
      PhoenixKit.Settings.update_setting_with_module(
        "shop_shipping_selection_position",
        "checkout",
        "shop"
      )

      {:ok, view, _html} = live(conn_for(conn, user, "USD"), "/checkout")
      billing = complete_billing("EE", "follows-shipping")
      view |> form("#checkout-billing-form", billing: billing) |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      price = "#checkout-shipping-price-#{method.uuid}"
      assert total_text(view, price) =~ "$10.00"

      {:ok, _} = Shop.redenominate_cart(Shop.get_cart(cart.uuid), "EUR")

      assert total_text(view, price) =~ "€9.09"
    end
  end
end
