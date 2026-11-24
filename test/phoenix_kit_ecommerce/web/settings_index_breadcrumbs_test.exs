defmodule PhoenixKitEcommerce.Web.SettingsIndexBreadcrumbsTest do
  @moduledoc """
  Admin Settings page: the switch for the shop index's breadcrumb row
  (`shop_show_index_breadcrumbs`), default on and gated on
  `shop.manage_settings`. It sits beside the cart-bar and Edit-button switches.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings

  @path "/en/admin/shop/settings"
  @key "shop_show_index_breadcrumbs"
  @toggle "#toggle-shop-show-index-breadcrumbs"

  setup %{conn: conn} do
    on_exit(fn ->
      {:ok, _} = Settings.update_setting(@key, "true")
      PhoenixKit.Cache.invalidate(:settings, @key)
    end)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "the switch is rendered next to the cart bar one, on by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, @toggle)
    assert has_element?(view, "#{@toggle}[checked]")
  end

  test "clicking it turns the setting off and on", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    view |> element(@toggle) |> render_click()

    assert Settings.get_setting(@key) == "false"
    refute has_element?(view, "#{@toggle}[checked]")

    view |> element(@toggle) |> render_click()

    assert Settings.get_setting(@key) == "true"
    assert has_element?(view, "#{@toggle}[checked]")
  end

  test "is refused without the settings capability", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))
    {:ok, view, _html} = live_narrowed(conn, @path)

    html = render_click(element(view, @toggle))

    assert html =~ "permission"
    refute Settings.get_setting(@key) == "false"
  end
end
