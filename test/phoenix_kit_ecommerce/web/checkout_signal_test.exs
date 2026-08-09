defmodule PhoenixKitEcommerce.Web.CheckoutSignalTest do
  @moduledoc """
  The checkout page's connected mount is the "buyer reached checkout"
  signal's only call site (`Notifications.checkout_started/1`, wired in
  `CheckoutPage.setup_checkout_assigns/3`). Covers the toggle-gated,
  connected-only, once-per-cart contract from the LiveView side.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Notifications, as: ShopNotifications

  test "connected checkout mount emits shop.checkout_started once", %{conn: conn} do
    # An admin recipient must exist for the assertion to be meaningful —
    # this is the first user registered in this sandboxed transaction, so
    # core auto-promotes it to Owner (see notifications_test.exs).
    _admin = PhoenixKitEcommerce.DataCase.fixture_user()
    admins = length(ShopNotifications.admin_recipients("shop.manage_carts"))
    assert admins > 0

    PhoenixKit.Settings.update_setting_with_module("shop_notify_checkout_started", "true", "shop")

    conn = setup_cart_session(conn)

    {:ok, _view, _html} = live(conn, "/checkout")

    assert count_notifications("shop.checkout_started") == admins

    # second mount (same cart) — no new notifications
    {:ok, _view, _html} = live(conn, "/checkout")
    assert count_notifications("shop.checkout_started") == admins
  end

  test "checkout mount stays silent while the toggle is off", %{conn: conn} do
    conn = setup_cart_session(conn)

    {:ok, _view, _html} = live(conn, "/checkout")

    assert count_notifications("shop.checkout_started") == 0
  end

  # Builds a digital-only cart (no shipping method required to reach
  # checkout) tied to a guest session, and plugs that session id into the
  # test conn the way `Web.Plugs.ShopSession` would in production.
  defp setup_cart_session(conn) do
    session_id = "checkout-signal-#{System.unique_integer([:positive])}"

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Signal Widget"},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false,
        "weight_grams" => 0
      })

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)

    Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})
  end
end
