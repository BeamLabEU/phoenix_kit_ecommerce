defmodule PhoenixKitEcommerce.Web.CartFollowsRequestCurrencyTest do
  @moduledoc """
  A signed-in shopper's active cart is found by user on every domain, and each
  domain has its own display currency. The cart page and the checkout page
  bring the cart into the REQUEST's currency when they mount
  (`PhoenixKitEcommerce.redenominate_cart/2`), because a cart is paid in the
  currency of the site it is paid on. A cart already in the request's currency
  is left alone: its rate stays frozen (§4.4).
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    on_exit(fn -> Currency.put_request_currency(nil) end)
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

    test "when it cannot be done the cart is shown as it is, with a notice, and the page lives",
         %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")
      [line] = cart.items

      Repo.update_all(from(i in CartItem, where: i.uuid == ^line.uuid),
        set: [base_unit_price: nil]
      )

      before = stored(cart.uuid)

      {:ok, view, _html} = live(conn_for(conn, user, "EUR"), "/cart")

      assert has_element?(view, "#test-flash-error")
      assert total_text(view, "#cart-summary-total") =~ "$"
      assert stored(cart.uuid) == before
    end

    test "a cart that is being paid is never touched",
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

    test "when it cannot be done the cart is shown as it is, with a notice, and the page lives",
         %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")
      [line] = cart.items

      Repo.update_all(from(i in CartItem, where: i.uuid == ^line.uuid),
        set: [base_unit_price: nil]
      )

      before = money(cart.uuid)

      {:ok, view, _html} = live(conn_for(conn, user, "EUR"), "/checkout")

      assert has_element?(view, "#test-flash-error")
      assert total_text(view, "#checkout-summary-total") =~ "$"
      assert money(cart.uuid) == before
    end

    test "a cart that is being paid is never touched",
         %{conn: conn, user: user, product: product} do
      cart = user_cart(user, product, "USD")

      Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: "converting"])
      before = money(cart.uuid)

      # No active cart: the page sends the shopper back to the cart page.
      assert {:error, {:live_redirect, _}} = live(conn_for(conn, user, "EUR"), "/checkout")
      assert money(cart.uuid) == before
    end
  end
end
