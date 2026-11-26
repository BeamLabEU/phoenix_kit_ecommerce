defmodule PhoenixKitEcommerce.Web.SettingsShipmentsTogglesTest do
  @moduledoc """
  Admin Settings page: the switch of the automatic shipment registration
  (shipping card) and of the buyer's shipped email (order emails card), each
  writing the setting its wrapper reads.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.OrderEmails

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "registering shipments on payment is off until switched on, and logged", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")
    refute has_element?(view, "#toggle-shipping-auto-create[checked]")

    view |> element("#toggle-shipping-auto-create") |> render_click()

    assert Shop.shipping_auto_create?()
    assert has_element?(view, "#toggle-shipping-auto-create[checked]")

    assert_activity_logged("shop.shipping_auto_create_changed",
      metadata_has: %{"enabled" => true}
    )

    view |> element("#toggle-shipping-auto-create") |> render_click()
    refute Shop.shipping_auto_create?()
  end

  test "the shipped email is on until switched off", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")
    assert has_element?(view, "#toggle-order-email-shipped[checked]")

    view |> element("#toggle-order-email-shipped") |> render_click()

    refute OrderEmails.shipped_emails_enabled?()
    refute has_element?(view, "#toggle-order-email-shipped[checked]")
  end
end
