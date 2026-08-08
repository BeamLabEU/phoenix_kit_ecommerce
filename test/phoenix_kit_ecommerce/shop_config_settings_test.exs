defmodule PhoenixKitEcommerce.ShopConfigSettingsTest do
  use PhoenixKitEcommerce.DataCase

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop

  describe "shipping_skip_mode/0" do
    test "defaults to :off" do
      assert Shop.shipping_skip_mode() == :off
    end

    test "reads fallback and always; unknown value degrades to :off" do
      Settings.update_setting_with_module("shop_shipping_skip_mode", "fallback", "shop")
      assert Shop.shipping_skip_mode() == :fallback
      Settings.update_setting_with_module("shop_shipping_skip_mode", "always", "shop")
      assert Shop.shipping_skip_mode() == :always
      Settings.update_setting_with_module("shop_shipping_skip_mode", "banana", "shop")
      assert Shop.shipping_skip_mode() == :off
    end
  end

  describe "shipping_selection_position/0" do
    test "defaults to :cart; reads checkout; unknown degrades to :cart" do
      assert Shop.shipping_selection_position() == :cart
      Settings.update_setting_with_module("shop_shipping_selection_position", "checkout", "shop")
      assert Shop.shipping_selection_position() == :checkout
      Settings.update_setting_with_module("shop_shipping_selection_position", "nope", "shop")
      assert Shop.shipping_selection_position() == :cart
    end
  end

  describe "notify_event?/1" do
    test "all three default to false and flip on" do
      refute Shop.notify_event?(:cart_first_item)
      refute Shop.notify_event?(:cart_item)
      refute Shop.notify_event?(:checkout_started)

      Settings.update_setting_with_module("shop_notify_cart_first_item", "true", "shop")
      Settings.update_setting_with_module("shop_notify_cart_item", "true", "shop")
      Settings.update_setting_with_module("shop_notify_checkout_started", "true", "shop")

      assert Shop.notify_event?(:cart_first_item)
      assert Shop.notify_event?(:cart_item)
      assert Shop.notify_event?(:checkout_started)
    end
  end
end
