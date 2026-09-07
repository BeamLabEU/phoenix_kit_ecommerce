defmodule PhoenixKitEcommerce.Catalogue.ExtensionEnabledTest do
  @moduledoc """
  Confirms `Extension.enabled?/0` actually tracks the `shop_enabled`
  setting — the gate that decides whether the Shop section appears in the
  catalogue forms at all. Runs `async: false`: it touches the global
  `shop_enabled` setting (same reason as
  `PhoenixKitEcommerce.Regression.PurchaseGuardsTest`).
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.Catalogue.Extension

  test "flips with the shop_enabled setting" do
    Settings.update_setting("shop_enabled", "true")
    assert Extension.enabled?() == true

    Settings.update_setting("shop_enabled", "false")
    on_exit(fn -> Settings.update_setting("shop_enabled", "true") end)

    assert Extension.enabled?() == false
  end
end
