defmodule PhoenixKitEcommerce.Web.SettingsRequirePhoneTest do
  @moduledoc "Admin Settings page: the \"Require a phone number at checkout\" switch."

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop

  @settings_path "/en/admin/shop/settings"
  @toggle "#toggle-shop-require-phone"

  setup %{conn: conn} do
    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_require_phone_at_checkout", false, "shop")
    end)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "the switch flips the setting and is audited", %{conn: conn} do
    {:ok, view, _html} = live(conn, @settings_path)

    refute has_element?(view, @toggle <> "[checked]")
    refute Shop.require_phone_at_checkout?()

    view |> element(@toggle) |> render_click()

    assert Shop.require_phone_at_checkout?()
    assert has_element?(view, @toggle <> "[checked]")

    row = assert_activity_logged("shop.checkout_phone_requirement_changed")
    assert row.metadata["require_phone"] == "true"

    view |> element(@toggle) |> render_click()

    refute Shop.require_phone_at_checkout?()
  end
end
