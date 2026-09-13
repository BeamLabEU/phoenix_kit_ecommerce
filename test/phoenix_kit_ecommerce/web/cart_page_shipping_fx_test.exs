defmodule PhoenixKitEcommerce.Web.CartPageShippingFxTest do
  @moduledoc """
  The cart page's shipping-method list renders each method's price and
  FREE badge through `PhoenixKitEcommerce.present_shipping_method/2`.
  `method.price` and `free_above_amount` are BASE authoring amounts (§4.7);
  rendering them next to the cart's own currency symbol labelled a $10.00
  method "€10.00" on a EUR cart, and comparing the EUR subtotal straight
  against a USD threshold decided the FREE badge on the wrong number.
  """
  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.Repo

  setup %{conn: conn} do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(Currency)
    on_exit(fn -> Currency.put_request_currency(nil) end)

    {:ok, _} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Shipped Widget"},
        "price" => Decimal.new("138.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 300
      })

    session_id = "cart-shipping-fx-#{System.unique_integer([:positive])}"
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    Currency.put_request_currency(nil)
    assert Decimal.equal?(cart.subtotal, Decimal.new("125.45"))

    # ONE init_test_session: put_test_currency/2 would overwrite shop_session_id
    conn =
      Plug.Test.init_test_session(conn, %{
        "shop_session_id" => session_id,
        "phoenix_kit_test_currency" => "EUR"
      })

    %{conn: conn}
  end

  test "a $10 base method lists as €9.09 on a EUR cart, never as €10.00", %{conn: conn} do
    {:ok, _} =
      Shop.create_shipping_method(%{
        "name" => "Flat Ten",
        "price" => Decimal.new("10.00"),
        "free_above_amount" => Decimal.new("1000.00"),
        "active" => true
      })

    {:ok, view, _html} = live(conn, "/cart")
    list = view |> element("#cart-shipping-methods") |> render()

    assert list =~ "€9.09"
    refute list =~ "€10.00"
    refute list =~ "FREE"
  end

  test "the FREE badge is decided on the BASE subtotal: €125.45 clears a $130 threshold",
       %{conn: conn} do
    {:ok, _} =
      Shop.create_shipping_method(%{
        "name" => "Free Over 130",
        "price" => Decimal.new("10.00"),
        "free_above_amount" => Decimal.new("130.00"),
        "active" => true
      })

    {:ok, view, _html} = live(conn, "/cart")
    list = view |> element("#cart-shipping-methods") |> render()

    # 125.45 (display) < 130 would deny it; 138.00 (base) clears it.
    assert list =~ "FREE"
    refute list =~ "€9.09"
    refute list =~ "€10.00"
  end
end
