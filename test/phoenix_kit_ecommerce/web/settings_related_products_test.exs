defmodule PhoenixKitEcommerce.Web.SettingsRelatedProductsTest do
  @moduledoc """
  Admin Settings page, "Related products" card: the category fallback switch
  and the block size, both audited and gated on `shop.manage_settings`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.RelatedProducts

  @path "/en/admin/shop/settings"

  setup %{conn: conn} do
    on_exit(fn ->
      Settings.update_setting("shop_related_fallback", "off")
      Settings.update_setting("shop_related_limit", "4")
    end)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "defaults: fallback off, four products", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert RelatedProducts.fallback() == :off
    assert RelatedProducts.limit() == 4
    refute has_element?(view, "#toggle-related-fallback[checked]")
    assert has_element?(view, "#related-limit option[selected][value='4']")
  end

  test "the fallback switch is stored and audited", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    view |> element("#toggle-related-fallback") |> render_click()

    assert RelatedProducts.fallback() == :category
    assert has_element?(view, "#toggle-related-fallback[checked]")
    row = assert_activity_logged("shop.related_products_changed")
    assert row.metadata["related_fallback"] == "category"

    view |> element("#toggle-related-fallback") |> render_click()
    assert RelatedProducts.fallback() == :off
  end

  test "the block size is stored and audited, a repeat is not", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    view |> form("#related-limit-form", %{"limit" => "8"}) |> render_change()

    assert RelatedProducts.limit() == 8
    row = assert_activity_logged("shop.related_products_changed")
    assert row.metadata["related_limit"] == 8
  end

  test "an out-of-range or malformed size is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    for value <- ["0", "13", "abc", "5.5", ""] do
      render_hook(view, "update_related_limit", %{"limit" => value})
    end

    render_hook(view, "update_related_limit", %{"limit" => 5})
    render_hook(view, "update_related_limit", %{})

    assert RelatedProducts.limit() == 4
  end

  test "is refused without the settings capability", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))
    {:ok, view, _html} = live_narrowed(conn, @path)

    render_hook(view, "toggle_related_fallback", %{})
    render_hook(view, "update_related_limit", %{"limit" => "9"})

    assert RelatedProducts.fallback() == :off
    assert RelatedProducts.limit() == 4
  end
end
