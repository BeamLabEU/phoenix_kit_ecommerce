defmodule PhoenixKitEcommerce.Web.SettingsAdminEditButtonTest do
  @moduledoc """
  Admin Settings page: the switch for the storefront's in-page admin Edit
  button (`shop_show_admin_edit_button`), default off and gated on
  `shop.manage_settings`. It sits beside the cart-bar switch.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings

  @path "/en/admin/shop/settings"
  @key "shop_show_admin_edit_button"

  setup %{conn: conn} do
    on_exit(fn ->
      {:ok, _} = Settings.update_setting(@key, "false")
      PhoenixKit.Cache.invalidate(:settings, @key)
    end)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "the switch is rendered next to the cart bar one, off by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#toggle-shop-show-admin-edit-button")
    refute has_element?(view, "#toggle-shop-show-admin-edit-button[checked]")
  end

  test "clicking it turns the setting on and off", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    view |> element("#toggle-shop-show-admin-edit-button") |> render_click()

    assert Settings.get_setting(@key) == "true"
    assert has_element?(view, "#toggle-shop-show-admin-edit-button[checked]")

    view |> element("#toggle-shop-show-admin-edit-button") |> render_click()

    assert Settings.get_setting(@key) == "false"
    refute has_element?(view, "#toggle-shop-show-admin-edit-button[checked]")
  end

  test "is refused without the settings capability", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))
    {:ok, view, _html} = live_narrowed(conn, @path)

    html = render_click(element(view, "#toggle-shop-show-admin-edit-button"))

    assert html =~ "permission"
    refute Settings.get_setting(@key) == "true"
  end
end
