defmodule PhoenixKitEcommerce.Web.SettingsStockTrackingTest do
  @moduledoc """
  Admin Settings page: the "Stock tracking" switch (spec 8.1, D13).

  The switch is a module setting that only takes effect while Warehouse is
  installed and enabled. The Warehouse side is stubbed (see
  `PhoenixKitEcommerce.Test.FakeWarehouse`), so these tests also run when the
  optional `phoenix_kit_warehouse` dependency is not resolved.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.FakeWarehouse

  @settings_path "/en/admin/shop/settings"
  @toggle "#toggle-shop-stock-tracking"
  @hint "#shop-stock-tracking-hint"
  @action "#stock-tracking-action"

  setup %{conn: conn} do
    # The settings cache is ETS-backed and is not rolled back by the sandbox.
    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_stock_tracking_enabled", false, "shop")
      Settings.update_setting_with_module("shop_stock_low_threshold", "0", "shop")
      Settings.update_setting_with_module("shop_stock_refund_action", "notify", "shop")
      FakeWarehouse.reset()
    end)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp action_attr(view, attr),
    do:
      view
      |> element(@action)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute(attr)
      |> List.first()

  # The hint is plain text: it must not contain a link, the button is the link.
  defp refute_hint_link(view), do: refute(has_element?(view, @hint <> " a"))

  describe "Warehouse not installed" do
    setup do: FakeWarehouse.put_not_installed()

    test "toggle is disabled and the button opens Modules -> Not installed", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      assert has_element?(view, @toggle <> "[disabled]")
      refute has_element?(view, @toggle <> "[checked]")
      assert has_element?(view, @toggle <> "[aria-describedby=shop-stock-tracking-hint]")

      assert has_element?(
               view,
               @hint,
               "Stock tracking needs the Warehouse module. Install it from Modules"
             )

      refute_hint_link(view)
      assert has_element?(view, "#shop-stock-tracking-card " <> @action)
      assert action_attr(view, "href") == Routes.path("/admin/modules?tab=not_installed")
      assert action_attr(view, "class") =~ "btn-primary"
      assert has_element?(view, @action, "Open Modules")
    end

    test "turning it on is refused by the server", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      html = render_hook(view, "toggle_shop_stock_tracking", %{})

      assert html =~ "Stock tracking was not turned on: the Warehouse module is not installed."
      refute Settings.get_boolean_setting("shop_stock_tracking_enabled", false)
      refute has_element?(view, @toggle <> "[checked]")
      refute Shop.stock_tracking_enabled?()
      refute_activity_logged("shop.stock_tracking_changed")
    end
  end

  describe "Warehouse installed but disabled" do
    setup do: FakeWarehouse.put_state(enabled: false)

    test "toggle is disabled and the button opens Modules -> Disabled", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      assert has_element?(view, @toggle <> "[disabled]")

      assert has_element?(
               view,
               @hint,
               "Stock tracking needs the Warehouse module. Enable it in Modules"
             )

      refute_hint_link(view)
      assert action_attr(view, "href") == Routes.path("/admin/modules?tab=disabled")
      assert action_attr(view, "class") =~ "btn-primary"
      assert has_element?(view, @action, "Enable Warehouse")
    end

    test "turning it on is refused by the server", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      html = render_hook(view, "toggle_shop_stock_tracking", %{})

      assert html =~ "Stock tracking was not turned on: the Warehouse module is disabled."
      refute Settings.get_boolean_setting("shop_stock_tracking_enabled", false)
      refute has_element?(view, @toggle <> "[checked]")
    end
  end

  describe "Warehouse enabled, no default location" do
    setup do: FakeWarehouse.put_state(enabled: true, default_location: nil)

    test "toggle is enabled and the button opens Warehouse settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      assert has_element?(view, @toggle)
      refute has_element?(view, @toggle <> "[disabled]")

      assert has_element?(
               view,
               @hint,
               "Choose a default warehouse in Warehouse settings first."
             )

      refute_hint_link(view)
      assert action_attr(view, "href") == Routes.path("/admin/settings/warehouse")
      assert action_attr(view, "class") =~ "btn-primary"
      assert has_element?(view, @action, "Set up Warehouse")
    end

    test "turning it on persists and logs", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      render_click(element(view, @toggle))

      assert Settings.get_boolean_setting("shop_stock_tracking_enabled", false)
      assert has_element?(view, @toggle <> "[checked]")
      assert Shop.stock_tracking_enabled?()

      assert_activity_logged("shop.stock_tracking_changed", metadata_has: %{"enabled" => true})
    end
  end

  describe "Warehouse enabled and configured" do
    setup do: FakeWarehouse.put_state(enabled: true, default_location: "loc-1")

    test "toggle is enabled and the button opens the Warehouse stock page", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      refute has_element?(view, @toggle <> "[disabled]")
      refute has_element?(view, @toggle <> "[checked]")
      assert has_element?(view, @hint, "Stock is kept by the Warehouse module.")
      refute has_element?(view, @hint, "Choose a default warehouse")
      refute_hint_link(view)
      assert action_attr(view, "href") == Routes.path("/admin/warehouse")
      assert action_attr(view, "class") =~ "btn-outline"
      refute action_attr(view, "class") =~ "btn-primary"
      assert has_element?(view, @action, "Open stock")
    end

    test "can be turned on and off again", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      render_click(element(view, @toggle))
      assert has_element?(view, @toggle <> "[checked]")
      assert Settings.get_boolean_setting("shop_stock_tracking_enabled", false)

      render_click(element(view, @toggle))
      refute has_element?(view, @toggle <> "[checked]")
      refute Settings.get_boolean_setting("shop_stock_tracking_enabled", false)

      assert_activity_logged("shop.stock_tracking_changed", metadata_has: %{"enabled" => false})
    end

    test "shows off once Warehouse is disabled, without touching the setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)
      render_click(element(view, @toggle))
      assert has_element?(view, @toggle <> "[checked]")

      FakeWarehouse.put_state(enabled: false)
      {:ok, view, _html} = live(conn, @settings_path)

      refute has_element?(view, @toggle <> "[checked]")
      assert has_element?(view, @toggle <> "[disabled]")
      assert Settings.get_boolean_setting("shop_stock_tracking_enabled", false)
      refute Shop.stock_tracking_enabled?()
    end
  end

  describe "the stock settings" do
    setup do
      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
      :ok
    end

    test "show only while tracking is on", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)
      refute has_element?(view, "#shop-stock-low-threshold-form")
      refute has_element?(view, "#shop-stock-refund-action-form")

      render_click(element(view, @toggle))

      assert has_element?(view, "#shop-stock-low-threshold[value=\"0\"]")
      assert has_element?(view, "#shop-stock-refund-action option[value=notify][selected]")
    end

    test "save how few are left before the page says so", %{conn: conn} do
      {:ok, true} = PhoenixKitEcommerce.StockTracking.set_enabled(true)
      {:ok, view, _html} = live(conn, @settings_path)

      html =
        view
        |> element("#shop-stock-low-threshold-form")
        |> render_submit(%{"threshold" => "5"})

      assert html =~ "Stock setting updated"
      assert PhoenixKitEcommerce.StockTracking.low_stock_threshold() == 5
      assert has_element?(view, "#shop-stock-low-threshold[value=\"5\"]")

      assert_activity_logged("shop.stock_low_threshold_changed",
        metadata_has: %{"threshold" => 5}
      )
    end

    test "refuse a threshold that is not a whole number", %{conn: conn} do
      {:ok, true} = PhoenixKitEcommerce.StockTracking.set_enabled(true)
      {:ok, view, _html} = live(conn, @settings_path)

      html =
        view
        |> element("#shop-stock-low-threshold-form")
        |> render_submit(%{"threshold" => "2.5"})

      assert html =~ "Enter a whole number from 0 to 1000."
      assert PhoenixKitEcommerce.StockTracking.low_stock_threshold() == 0
    end

    test "choose what a refund does", %{conn: conn} do
      {:ok, true} = PhoenixKitEcommerce.StockTracking.set_enabled(true)
      {:ok, view, _html} = live(conn, @settings_path)

      view
      |> element("#shop-stock-refund-action-form")
      |> render_change(%{"action" => "receipt"})

      assert PhoenixKitEcommerce.StockTracking.refund_action() == "receipt"
      assert has_element?(view, "#shop-stock-refund-action option[value=receipt][selected]")

      assert_activity_logged("shop.stock_refund_action_changed",
        metadata_has: %{"action" => "receipt"}
      )

      html =
        view
        |> element("#shop-stock-refund-action-form")
        |> render_change(%{"action" => "restock"})

      assert html =~ "Choose what a refund does to the stock."
      assert PhoenixKitEcommerce.StockTracking.refund_action() == "receipt"
    end
  end
end
