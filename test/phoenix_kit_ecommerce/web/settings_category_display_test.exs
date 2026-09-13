defmodule PhoenixKitEcommerce.Web.SettingsCategoryDisplayTest do
  @moduledoc """
  Admin Settings page: the category name display (`shop_category_name_display`)
  and category icon (`shop_category_icon_mode`) radio groups only ever
  store the values their storefront readers understand — a crafted
  event payload is refused with a flash, never persisted.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  describe "update_category_display" do
    test "stores truncate and wrap", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      render_click(view, "update_category_display", %{"display" => "wrap"})
      assert Settings.get_setting("shop_category_name_display") == "wrap"

      render_click(view, "update_category_display", %{"display" => "truncate"})
      assert Settings.get_setting("shop_category_name_display") == "truncate"
    end

    test "refuses any other value", %{conn: conn} do
      Settings.update_setting("shop_category_name_display", "wrap")
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      html = render_click(view, "update_category_display", %{"display" => "marquee"})
      assert html =~ "Invalid value"
      assert Settings.get_setting("shop_category_name_display") == "wrap"

      html = render_click(view, "update_category_display", %{"display" => ["wrap"]})
      assert html =~ "Invalid value"
      assert Settings.get_setting("shop_category_name_display") == "wrap"

      html = render_click(view, "update_category_display", %{})
      assert html =~ "Invalid value"
    end
  end

  describe "update_category_icon" do
    test "stores the three modes the sidebar renders", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      for mode <- ~w(folder category none) do
        render_click(view, "update_category_icon", %{"mode" => mode})
        assert Settings.get_setting("shop_category_icon_mode") == mode
      end
    end

    test "refuses any other value", %{conn: conn} do
      Settings.update_setting("shop_category_icon_mode", "folder")
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      html = render_click(view, "update_category_icon", %{"mode" => "<script>"})
      assert html =~ "Invalid value"
      assert Settings.get_setting("shop_category_icon_mode") == "folder"

      html = render_click(view, "update_category_icon", %{"mode" => %{"x" => "y"}})
      assert html =~ "Invalid value"
      assert Settings.get_setting("shop_category_icon_mode") == "folder"
    end
  end
end
