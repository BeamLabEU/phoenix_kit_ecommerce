defmodule PhoenixKitEcommerce.Web.SettingsShippingModesTest do
  @moduledoc """
  Admin Settings page: the shipping-requirement card.

  `shop_shipping_skip_mode` and `shop_shipping_selection_position` shipped
  read-only — the storefront and `convert_cart_to_order/2` both honored
  them from day one, but nothing rendered a control, so the only way to
  change either was to write the setting row by hand.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "renders the shipping card", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/shop/settings")
    assert html =~ ~s(id="shop-shipping-modes-card")
  end

  test "skip-mode radios write the setting the context reads", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    render_click(element(view, "#shipping-skip-mode-fallback"))
    assert Shop.shipping_skip_mode() == :fallback

    render_click(element(view, "#shipping-skip-mode-always"))
    assert Shop.shipping_skip_mode() == :always

    render_click(element(view, "#shipping-skip-mode-off"))
    assert Shop.shipping_skip_mode() == :off
  end

  test "position radios write the setting the storefront reads", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    render_click(element(view, "#shipping-position-checkout"))
    assert Shop.shipping_selection_position() == :checkout

    render_click(element(view, "#shipping-position-cart"))
    assert Shop.shipping_selection_position() == :cart
  end

  test "a value outside the closed enum is rejected, not stored", %{conn: conn} do
    # Both readers fall back to the safe legacy value on anything they don't
    # recognise, so an unvalidated write would read as the setting being
    # silently ignored.
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    render_click(view, "update_shipping_skip_mode", %{"mode" => "banana"})
    assert PhoenixKit.Settings.get_setting("shop_shipping_skip_mode") != "banana"

    render_click(view, "update_shipping_selection_position", %{"position" => "nope"})
    assert PhoenixKit.Settings.get_setting("shop_shipping_selection_position") != "nope"
  end
end
