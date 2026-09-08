defmodule PhoenixKitEcommerce.Web.StorefrontAdminEditTest do
  @moduledoc """
  The storefront's shop index, category and product pages each show an
  "Edit" link into the matching admin page — but only for a visitor who
  can access the admin area. `Web.Helpers.maybe_assign_admin_edit/3`
  delegates to core's `PhoenixKitWeb.AdminEditHelper.assign_admin_edit/3`,
  which itself gates on `Scope.can_access_admin_area?/1`; these drive the
  three real LiveViews end-to-end (anonymous vs. admin scope) to prove the
  assign - and the render guard around it - actually withhold/show the
  link, not just that the helper function is correct in isolation.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  defp create_category_with_dialect_slug!(name) do
    {:ok, category} = Shop.create_category(%{"name" => %{"en" => name}})

    {:ok, category} =
      Shop.update_category(category, %{
        "name" => Map.put(category.name, "en-US", name),
        "slug" => Map.put(category.slug, "en-US", category.slug["en"])
      })

    category
  end

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  describe "shop index (/shop)" do
    test "anonymous visitor gets no admin edit assign or link", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/shop")

      refute html =~ "admin_edit_url"
      refute html =~ "Manage Shop"
    end

    test "admin visitor sees a Manage Shop link to /admin/shop", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, html} = live(conn, "/shop")

      assert html =~ "Manage Shop"
      assert view |> element(~s{a[href="/en/admin/shop"]}) |> has_element?()
    end
  end

  describe "category page (/shop/category/:slug)" do
    setup do
      category = create_category_with_dialect_slug!("Ergonomic Mask")
      %{category: category, path: "/shop/category/#{category.slug["en-US"]}"}
    end

    test "anonymous visitor gets no admin edit assign or link", %{conn: conn, path: path} do
      {:ok, _view, html} = live(conn, path)

      refute html =~ "Edit Category"
    end

    test "admin visitor sees an Edit Category link to the matching admin page", %{
      conn: conn,
      path: path,
      category: category
    } do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, html} = live(conn, path)

      assert html =~ "Edit Category"

      assert view
             |> element(~s{a[href="/en/admin/shop/categories/#{category.uuid}/edit"]})
             |> has_element?()
    end
  end

  describe "product page (/shop/product/:slug)" do
    setup do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Ergonomic Flower Pot"},
          "slug" => %{lang() => "ergonomic-flower-pot-#{System.unique_integer([:positive])}"},
          "price" => Decimal.new("10.00"),
          "status" => "active"
        })

      %{product: product, path: "/shop/product/#{product.slug[lang()]}"}
    end

    test "anonymous visitor gets no admin edit assign or link", %{conn: conn, path: path} do
      {:ok, _view, html} = live(conn, path)

      refute html =~ "Edit Product"
    end

    test "admin visitor sees an Edit Product link to the matching admin page", %{
      conn: conn,
      path: path,
      product: product
    } do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, html} = live(conn, path)

      assert html =~ "Edit Product"

      assert view
             |> element(~s{a[href="/en/admin/shop/products/#{product.uuid}/edit"]})
             |> has_element?()
    end
  end
end
