defmodule PhoenixKitEcommerce.Web.StorefrontAdminEditMenuTest do
  @moduledoc """
  The storefront hands the page's admin Edit target to the layout, so a
  host's account menu (core's `UserDashboardNav.user_dropdown/1` or a host's
  own) can show it, and the in-page button beside the cart bar is a
  separate, default-off switch (`shop_show_admin_edit_button`).

  The host layout here is `Test.Layouts.host/1`, which renders what core's
  `LayoutWrapper.app_layout` passes a host layout as `#host-admin-edit`.
  Each page is driven for an admin with the shop permission, an admin
  without it, and a guest.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop

  setup do
    previous = Application.fetch_env(:phoenix_kit, :layout)
    Application.put_env(:phoenix_kit, :layout, {PhoenixKitEcommerce.Test.Layouts, :host})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :layout, value)
        :error -> Application.delete_env(:phoenix_kit, :layout)
      end
    end)

    :ok
  end

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  # `.btn` in-page link; the storefront bar is the only place that renders it.
  defp page_button?(view, text) do
    has_element?(view, "a.btn", text)
  end

  describe "shop index (/shop)" do
    test "an admin's layout receives the Manage Shop target", %{conn: conn} do
      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), "/shop")

      assert has_element?(view, "#host-admin-edit[data-url='#{Routes.path("/admin/shop")}']")
      assert has_element?(view, "#host-admin-edit[data-label='Manage Shop']")
    end

    test "a guest's layout receives nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/shop")

      refute has_element?(view, "#host-admin-edit")
    end

    test "an admin without any shop permission gets nothing", %{conn: conn} do
      {:ok, view, _html} = live(put_test_scope(conn, fake_scope(permissions: [])), "/shop")

      refute has_element?(view, "#host-admin-edit")
    end
  end

  describe "category page" do
    setup do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Menu Category"}})

      # The storefront resolves the slug under the dialect locale, the way
      # `storefront_admin_edit_test.exs` seeds it.
      {:ok, category} =
        Shop.update_category(category, %{
          "name" => Map.put(category.name, "en-US", "Menu Category"),
          "slug" => Map.put(category.slug, "en-US", category.slug["en"])
        })

      %{category: category, path: "/shop/category/#{category.slug["en-US"]}"}
    end

    test "an admin's layout receives the editor URL and label", %{
      conn: conn,
      path: path,
      category: category
    } do
      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), path)

      assert has_element?(view, "#host-admin-edit[data-label='Edit Category']")

      assert has_element?(
               view,
               "#host-admin-edit[data-url*='/admin/shop/categories/#{category.uuid}/edit']"
             )
    end

    test "a guest and an admin without shop.manage_catalog get nothing", %{
      conn: conn,
      path: path
    } do
      {:ok, guest, _html} = live(conn, path)
      refute has_element?(guest, "#host-admin-edit")

      {:ok, limited, _html} = live(put_test_scope(conn, fake_scope(permissions: ["shop"])), path)
      refute has_element?(limited, "#host-admin-edit")
    end
  end

  describe "product page" do
    setup do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Menu Flower Pot"},
          "slug" => %{lang() => "menu-flower-pot-#{System.unique_integer([:positive])}"},
          "price" => Decimal.new("10.00"),
          "status" => "active"
        })

      %{product: product, path: "/shop/product/#{product.slug[lang()]}"}
    end

    test "an admin's layout receives the editor URL and label", %{
      conn: conn,
      path: path,
      product: product
    } do
      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), path)

      assert has_element?(view, "#host-admin-edit[data-label='Edit Product']")

      assert has_element?(
               view,
               "#host-admin-edit[data-url*='/admin/shop/products/#{product.uuid}/edit']"
             )
    end

    test "a guest and an admin without shop.manage_catalog get nothing", %{
      conn: conn,
      path: path
    } do
      {:ok, guest, _html} = live(conn, path)
      refute has_element?(guest, "#host-admin-edit")

      {:ok, limited, _html} = live(put_test_scope(conn, fake_scope(permissions: ["shop"])), path)
      refute has_element?(limited, "#host-admin-edit")
    end
  end

  describe "the in-page Edit button (shop_show_admin_edit_button)" do
    setup do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Button Flower Pot"},
          "slug" => %{lang() => "button-flower-pot-#{System.unique_integer([:positive])}"},
          "price" => Decimal.new("10.00"),
          "status" => "active"
        })

      %{path: "/shop/product/#{product.slug[lang()]}"}
    end

    test "is off by default: the page has no button, the layout still has the target", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), path)

      refute page_button?(view, "Edit Product")
      assert has_element?(view, "#host-admin-edit")
    end

    test "an explicit off keeps the button away", %{conn: conn, path: path} do
      put_admin_edit_button!("false")

      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), path)

      refute page_button?(view, "Edit Product")
    end

    test "with the setting on, the button renders for an admin", %{conn: conn, path: path} do
      put_admin_edit_button!("true")

      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), path)

      assert page_button?(view, "Edit Product")
      assert has_element?(view, "#host-admin-edit")
    end

    test "with the setting on, a guest still sees no button", %{conn: conn, path: path} do
      put_admin_edit_button!("true")

      {:ok, view, _html} = live(conn, path)

      refute page_button?(view, "Edit Product")
    end

    test "the setting does not touch the cart link", %{conn: conn, path: path} do
      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), path)

      assert has_element?(view, "a.btn", "Cart")
    end
  end
end
