defmodule PhoenixKitEcommerce.Web.SettingsSidebarLayoutTest do
  @moduledoc """
  Admin Settings page, "Sidebar Display" card: the sidebar switch
  (`shop_sidebar_enabled`) and the category display radio
  (`shop_category_display`), both audited and gated on `shop.manage_settings`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.Web.Helpers

  @path "/en/admin/shop/settings"

  setup %{conn: conn} do
    on_exit(fn ->
      Settings.update_setting("shop_sidebar_enabled", "true")
      Settings.update_setting("shop_category_display", "cards")
    end)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "the readers default to the current layout" do
    assert Helpers.sidebar_enabled?()
    assert Helpers.category_display() == "cards"
  end

  describe "toggle_sidebar_enabled" do
    test "flips the setting, shows it and writes the audit row", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#toggle-shop-sidebar-enabled[checked]")

      view |> element("#toggle-shop-sidebar-enabled") |> render_click()

      refute Helpers.sidebar_enabled?()
      refute has_element?(view, "#toggle-shop-sidebar-enabled[checked]")

      row = assert_activity_logged("shop.sidebar_layout_changed")
      assert row.metadata["sidebar_enabled"] == false

      view |> element("#toggle-shop-sidebar-enabled") |> render_click()

      assert Helpers.sidebar_enabled?()
    end

    test "is refused without the settings capability", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))
      {:ok, view, _html} = live_narrowed(conn, @path)

      html = render_click(element(view, "#toggle-shop-sidebar-enabled"))

      assert html =~ "permission"
      assert Helpers.sidebar_enabled?()
      refute_activity_logged("shop.sidebar_layout_changed")
    end
  end

  describe "update_category_display_mode" do
    test "stores cards and buttons and writes the audit row", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      render_click(view, "update_category_display_mode", %{"mode" => "buttons"})
      assert Helpers.category_display() == "buttons"

      row = assert_activity_logged("shop.category_display_changed")
      assert row.metadata["category_display"] == "buttons"

      render_click(view, "update_category_display_mode", %{"mode" => "cards"})
      assert Helpers.category_display() == "cards"
    end

    test "refuses any other value", %{conn: conn} do
      Settings.update_setting("shop_category_display", "buttons")
      {:ok, view, _html} = live(conn, @path)

      for bad <- ["chips", ["buttons"], %{"x" => "y"}] do
        html = render_click(view, "update_category_display_mode", %{"mode" => bad})
        assert html =~ "Invalid value"
      end

      html = render_click(view, "update_category_display_mode", %{})
      assert html =~ "Invalid value"
      assert Helpers.category_display() == "buttons"
      refute_activity_logged("shop.category_display_changed")
    end

    test "the radios mirror the stored mode and carry the event payload", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      radio = ~s(input[type=radio][name="category_display_mode"])
      assert has_element?(view, ~s|#{radio}[value=cards][phx-value-mode=cards][checked]|)

      assert has_element?(
               view,
               ~s|#{radio}[value=buttons][phx-value-mode=buttons]:not([checked])|
             )

      view |> element(~s(#{radio}[value=buttons])) |> render_click()

      assert has_element?(view, ~s|#{radio}[value=buttons][checked]|)
      assert has_element?(view, ~s|#{radio}[value=cards]:not([checked])|)
      assert Helpers.category_display() == "buttons"
    end

    test "choosing the mode already selected writes no audit row", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      render_click(view, "update_category_display_mode", %{"mode" => "cards"})

      refute_activity_logged("shop.category_display_changed")
      assert Helpers.category_display() == "cards"
    end

    test "falls back to cards when the stored value is not understood" do
      Settings.update_setting("shop_category_display", "marquee")

      assert Helpers.category_display() == "cards"
    end

    test "is refused without the settings capability", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))
      {:ok, view, _html} = live_narrowed(conn, @path)

      html = render_click(view, "update_category_display_mode", %{"mode" => "buttons"})

      assert html =~ "permission"
      assert Helpers.category_display() == "cards"
      refute_activity_logged("shop.category_display_changed")
    end
  end
end
