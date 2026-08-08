defmodule PhoenixKitEcommerce.Web.CheckoutCompleteCopyTest do
  @moduledoc """
  The order-confirmation page's "we will contact you" notice for orders
  that skipped shipping (`order.metadata["shipping_skipped"]`, stamped by
  `convert_cart_to_order/2` under `shop_shipping_skip_mode` - see
  `PhoenixKitEcommerce.ConvertSkipShippingTest`). A shopper who never
  picked a shipping method still needs to know delivery is being arranged,
  not just that the order was placed.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  test "completion page shows contact-you copy for shipping-skipped orders", %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module("shop_shipping_skip_mode", "always", "shop")

    session_id = "checkout-complete-copy-#{System.unique_integer([:positive])}"
    order = create_skipped_shipping_order(session_id)

    conn = session_conn_for(conn, session_id)

    {:ok, _view, html} = live(conn, "/checkout/complete/#{order.uuid}")

    assert html =~ "id=\"shipping-pending-notice\""
  end

  test "completion page omits the notice for orders that got a shipping method",
       %{conn: conn} do
    session_id = "checkout-complete-copy-shipped-#{System.unique_integer([:positive])}"
    order = create_shipped_order(session_id)

    conn = session_conn_for(conn, session_id)

    {:ok, _view, html} = live(conn, "/checkout/complete/#{order.uuid}")

    refute html =~ "id=\"shipping-pending-notice\""
  end

  # A physical cart converted with no shipping method, under
  # `shop_shipping_skip_mode: "always"` — same fixture shape as
  # `ConvertSkipShippingTest`, minus the shipping method.
  defp create_skipped_shipping_order(session_id) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Completion Copy Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE"))

    order
  end

  defp create_shipped_order(session_id) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Completion Copy Widget Shipped"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Standard",
        "price" => Decimal.new("5.00"),
        "active" => true,
        "countries" => ["EE"]
      })

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "EE")

    {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE"))

    order
  end

  defp complete_billing(country) do
    %{
      "email" => "checkout-complete-copy-#{System.unique_integer([:positive])}@example.com",
      "first_name" => "Test",
      "last_name" => "Buyer",
      "address_line1" => "1 Test Street",
      "city" => "Testville",
      "postal_code" => "10001",
      "country" => country
    }
  end

  # `CheckoutComplete.mount/2` only grants access via a TRUSTED shop
  # session — `shop_session_trusted: true` in the Phoenix session, the way
  # `Web.Plugs.ShopSession` marks a signed cookie's value (see its
  # moduledoc). Tests bypass that plug, so the trust flag is set directly.
  defp session_conn_for(conn, session_id) do
    Plug.Test.init_test_session(conn, %{
      "shop_session_id" => session_id,
      "shop_session_trusted" => true
    })
  end
end
