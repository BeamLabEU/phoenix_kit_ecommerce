defmodule PhoenixKitEcommerce.Web.StorefrontTopRowTest do
  @moduledoc """
  What the top of each storefront page holds, and that nothing is left behind
  when the cart bar and the Edit button are both off.

  The shop index is the shop's front page: its only crumb would be itself, a
  label that links nowhere above a heading that already says where the visitor
  is. It renders no breadcrumbs, so with the bar off its first element is the
  heading block and with the bar on it is the bar alone.

  The category and product pages keep their breadcrumb row; with the bar off
  that row holds the breadcrumbs and nothing else.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp category_path do
    {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Top Row Category"}})

    {:ok, category} =
      Shop.update_category(category, %{
        "name" => Map.put(category.name, lang(), "Top Row Category"),
        "slug" => Map.put(category.slug, lang(), category.slug["en"])
      })

    "/shop/category/#{category.slug[lang()]}"
  end

  defp product_path do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Top Row Product", lang() => "Top Row Product"},
        "slug" => %{lang() => "top-row-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false
      })

    "/shop/product/#{product.slug[lang()]}"
  end

  # The page container is the first element inside the layout's content.
  @index_page "div.max-w-7xl.mx-auto"
  @category_page "div.max-w-7xl.mx-auto"
  @product_page "div.container.mx-auto"

  describe "shop index" do
    test "has no breadcrumb row: the heading block is the first thing on the page", %{conn: conn} do
      put_cart_bar!("false")

      {:ok, view, _html} = live(conn, "/shop")

      refute has_element?(view, ".breadcrumbs")
      refute has_element?(view, "[data-storefront-bar]")
      assert has_element?(view, "#{@index_page} > header:first-child h1")
    end

    test "bar on: the bar alone is the first thing, right-aligned, no breadcrumbs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/shop")

      refute has_element?(view, ".breadcrumbs")
      assert has_element?(view, "#{@index_page} > [data-storefront-bar].justify-end:first-child")
      assert has_element?(view, "[data-storefront-bar] a.btn", "Cart")
    end
  end

  describe "category page" do
    test "bar off: the first row holds the breadcrumbs and nothing else", %{conn: conn} do
      put_cart_bar!("false")

      {:ok, view, _html} = live(conn, category_path())

      refute has_element?(view, "[data-storefront-bar]")
      assert has_element?(view, "#{@category_page} > div:first-child > .breadcrumbs")
      refute has_element?(view, "#{@category_page} > div:first-child > :not(.breadcrumbs)")
    end

    test "bar on: breadcrumbs and bar share the first row", %{conn: conn} do
      {:ok, view, _html} = live(conn, category_path())

      assert has_element?(view, "#{@category_page} > div:first-child > .breadcrumbs")
      assert has_element?(view, "#{@category_page} > div:first-child > [data-storefront-bar]")
    end
  end

  describe "product page" do
    test "bar off: the first row holds the breadcrumbs and nothing else", %{conn: conn} do
      put_cart_bar!("false")

      {:ok, view, _html} = live(conn, product_path())

      refute has_element?(view, "[data-storefront-bar]")
      assert has_element?(view, "#{@product_page} > div:first-child > .breadcrumbs")
      refute has_element?(view, "#{@product_page} > div:first-child > :not(.breadcrumbs)")
    end

    test "bar on: breadcrumbs and bar share the first row", %{conn: conn} do
      {:ok, view, _html} = live(conn, product_path())

      assert has_element?(view, "#{@product_page} > div:first-child > .breadcrumbs")
      assert has_element?(view, "#{@product_page} > div:first-child > [data-storefront-bar]")
    end
  end
end
