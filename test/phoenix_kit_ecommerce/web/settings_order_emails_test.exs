defmodule PhoenixKitEcommerce.Web.SettingsOrderEmailsTest do
  @moduledoc "The Order emails card of the shop settings page."

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce.OrderEmails

  @form "#shop-order-email-recipients-form"

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "buyer emails start on and can be turned off", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    assert has_element?(view, "#toggle-order-emails-to-buyer[checked]")

    view |> element("#toggle-order-emails-to-buyer") |> render_click()

    refute has_element?(view, "#toggle-order-emails-to-buyer[checked]")
    refute OrderEmails.buyer_emails_enabled?()
  end

  test "saves the shop's addresses and shows them back", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    view |> form(@form, addresses: "a@example.com; b@example.com") |> render_submit()

    assert OrderEmails.shop_recipients() == ["a@example.com", "b@example.com"]

    assert has_element?(
             view,
             "#shop-order-email-recipients[value='a@example.com, b@example.com']"
           )
  end

  test "says which address is wrong and stores nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    html = view |> form(@form, addresses: "a@example.com, nonsense") |> render_submit()

    assert html =~ "Not an email address: nonsense"
    assert OrderEmails.shop_recipients() == []
  end
end
