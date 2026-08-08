defmodule PhoenixKitEcommerce.Web.SettingsNotificationsTest do
  @moduledoc """
  Admin Settings page: the storefront-notifications card added in
  PhoenixKitEcommerce.Web.Settings — the three cart/checkout notify
  toggles and the recipient checkbox list.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "renders the notifications card", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/shop/settings")
    assert html =~ ~s(id="shop-notifications-card")
  end

  test "toggles flip the three notify settings", %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/shop/settings")
    assert html =~ ~s(id="shop-notifications-card")

    render_click(element(view, "#toggle-notify-cart-first-item"))
    assert PhoenixKit.Settings.get_setting("shop_notify_cart_first_item") == "true"

    render_click(element(view, "#toggle-notify-cart-item"))
    assert PhoenixKit.Settings.get_setting("shop_notify_cart_item") == "true"

    render_click(element(view, "#toggle-notify-checkout-started"))
    assert PhoenixKit.Settings.get_setting("shop_notify_checkout_started") == "true"
  end

  test "recipient checkboxes persist the JSON list", %{conn: conn} do
    # First registered user in this sandboxed transaction is auto-promoted
    # to Owner by core, which is what makes it a candidate recipient (see
    # `Notifications.admin_recipients/1` and the same convention used in
    # notifications_test.exs / checkout_signal_test.exs).
    admin = PhoenixKitEcommerce.DataCase.fixture_user()

    {:ok, view, html} = live(conn, "/en/admin/shop/settings")
    assert html =~ admin.email

    view
    |> element("#shop-notification-recipients-form")
    |> render_submit(%{"recipients" => %{admin.uuid => "true"}})

    assert PhoenixKit.Settings.get_json_setting("shop_notification_recipients") == %{
             "uuids" => [admin.uuid]
           }
  end
end
