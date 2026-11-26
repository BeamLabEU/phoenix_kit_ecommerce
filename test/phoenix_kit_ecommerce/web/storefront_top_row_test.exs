defmodule PhoenixKitEcommerce.Web.StorefrontTopRowTest do
  @moduledoc """
  What the top of each storefront page holds, and that nothing is left behind
  when the cart bar and the Edit button are both off.

  The shop index is the shop's front page: its only crumb is itself, a label
  that links nowhere above a heading that already says where the visitor is.
  `shop_show_index_breadcrumbs` (default on) decides whether that one-crumb row
  is rendered. On, the crumb and the bar share one row. Off, the index has no
  breadcrumbs: the bar sits alone, right-aligned, and with the bar off too the
  heading block is the first thing on the page.

  The category and product pages keep their breadcrumb row either way; with
  the bar off that row holds the breadcrumbs and nothing else. The setting
  does not touch them.
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

  describe "shop index, breadcrumbs on (the default)" do
    test "bar on: the crumb and the bar share the first row", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/shop")

      assert has_element?(
               view,
               "#{@index_page} > div.flex.flex-wrap.items-center.justify-between.gap-3.mb-4:first-child > .breadcrumbs.text-sm li.font-medium"
             )

      assert has_element?(view, "#{@index_page} > div:first-child > .breadcrumbs .hero-home")
      assert has_element?(view, "#{@index_page} > div:first-child > [data-storefront-bar]")
      assert has_element?(view, "[data-storefront-bar] a.btn", "Cart")
      refute has_element?(view, "#{@index_page} > [data-storefront-bar]")
    end

    test "bar off: the first row holds the crumb and nothing else", %{conn: conn} do
      put_cart_bar!("false")

      {:ok, view, _html} = live(conn, "/shop")

      refute has_element?(view, "[data-storefront-bar]")
      assert has_element?(view, "#{@index_page} > div:first-child > .breadcrumbs")
      refute has_element?(view, "#{@index_page} > div:first-child > :not(.breadcrumbs)")
    end

    test "a stored value that is not \"false\" counts as on", %{conn: conn} do
      put_index_breadcrumbs!("TRUE")

      {:ok, view, _html} = live(conn, "/shop")

      assert has_element?(view, "#{@index_page} > div:first-child > .breadcrumbs")
    end

    test "explicitly on behaves as the default", %{conn: conn} do
      put_index_breadcrumbs!("true")

      {:ok, view, _html} = live(conn, "/shop")

      assert has_element?(view, "#{@index_page} > div:first-child > .breadcrumbs")
      assert has_element?(view, "#{@index_page} > div:first-child > [data-storefront-bar]")
      refute has_element?(view, "#{@index_page} > [data-storefront-bar]")
    end
  end

  describe "shop index, breadcrumbs off" do
    setup do
      put_index_breadcrumbs!("false")
    end

    test "admin with the Edit button and the cart bar on: both links in the one bar", %{
      conn: conn
    } do
      put_admin_edit_button!("true")
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/shop")

      refute has_element?(view, ".breadcrumbs")

      assert has_element?(
               view,
               "#{@index_page} > [data-storefront-bar].justify-end.mb-4:first-child a.btn",
               "Manage Shop"
             )

      assert has_element?(
               view,
               "#{@index_page} > [data-storefront-bar].justify-end.mb-4:first-child a.btn",
               "Cart"
             )
    end

    test "bar and Edit button off: the heading block is the first thing on the page", %{
      conn: conn
    } do
      put_cart_bar!("false")

      {:ok, view, _html} = live(conn, "/shop")

      refute has_element?(view, ".breadcrumbs")
      refute has_element?(view, "[data-storefront-bar]")
      assert has_element?(view, "#{@index_page} > header:first-child h1")
    end

    test "bar on: the bar alone is the first thing, right-aligned, no breadcrumbs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/shop")

      refute has_element?(view, ".breadcrumbs")

      assert has_element?(
               view,
               "#{@index_page} > [data-storefront-bar].justify-end.mb-4:first-child"
             )

      assert has_element?(view, "[data-storefront-bar] a.btn", "Cart")
    end

    test "cart bar off, Edit button on for an admin: the Edit button alone, right-aligned", %{
      conn: conn
    } do
      put_cart_bar!("false")
      put_admin_edit_button!("true")
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/shop")

      refute has_element?(view, ".breadcrumbs")

      assert has_element?(
               view,
               "#{@index_page} > [data-storefront-bar].justify-end.mb-4:first-child"
             )

      assert has_element?(view, "[data-storefront-bar] a.btn", "Manage Shop")
      refute has_element?(view, "[data-storefront-bar] a", "Cart")
    end

    test "cart bar off, Edit button on for a guest: no empty bar, heading is first", %{
      conn: conn
    } do
      put_cart_bar!("false")
      put_admin_edit_button!("true")

      {:ok, view, _html} = live(conn, "/shop")

      refute has_element?(view, ".breadcrumbs")
      refute has_element?(view, "[data-storefront-bar]")
      assert has_element?(view, "#{@index_page} > header:first-child h1")
    end
  end

  for index_breadcrumbs <- ["true", "false"] do
    describe "category page, index breadcrumbs #{index_breadcrumbs}" do
      setup do
        put_index_breadcrumbs!(unquote(index_breadcrumbs))
      end

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
  end

  for index_breadcrumbs <- ["true", "false"] do
    describe "product page, index breadcrumbs #{index_breadcrumbs}" do
      setup do
        put_index_breadcrumbs!(unquote(index_breadcrumbs))
      end

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
end
