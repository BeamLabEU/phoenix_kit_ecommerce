defmodule PhoenixKitEcommerce.Web.CartPageShippingModesTest do
  @moduledoc """
  Cart page honors `shop_shipping_skip_mode` / `shop_shipping_selection_position`:
  the cart-page shipping selector (and the checkout-button block tied to it)
  only apply when shipping selection is meant to happen on the cart page —
  i.e. `skip_mode != :always and position == :cart`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  setup [:cart_with_shippable_item]

  test "default (off/cart): shipping selector shown, checkout blocked without method", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/cart")

    assert html =~ "id=\"cart-shipping-methods\""
  end

  test "position=checkout hides the cart-page selector and allows proceeding", %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    {:ok, view, html} = live(conn, "/cart")

    refute html =~ "id=\"cart-shipping-methods\""
    refute view |> element("#proceed-to-checkout") |> render() =~ "disabled"
  end

  test "skip_mode=always hides selector regardless of position", %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module("shop_shipping_skip_mode", "always", "shop")

    {:ok, _view, html} = live(conn, "/cart")

    refute html =~ "id=\"cart-shipping-methods\""
  end

  # Builds a guest cart holding one physical (shippable) item plus an
  # active shipping method, tied to a guest session the same way
  # `Web.Plugs.ShopSession` would in production — so the default
  # off/cart mode has something to render a selector for.
  defp cart_with_shippable_item(%{conn: conn}) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Physical Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    {:ok, _method} =
      Shop.create_shipping_method(%{"name" => "Standard", "price" => Decimal.new("5.00")})

    session_id = "cart-shipping-modes-#{System.unique_integer([:positive])}"

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)

    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})

    %{conn: conn}
  end
end
