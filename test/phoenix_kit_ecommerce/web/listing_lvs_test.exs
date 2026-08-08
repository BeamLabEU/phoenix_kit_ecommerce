defmodule PhoenixKitEcommerce.Web.ListingLvsTest do
  @moduledoc """
  LiveView smoke tests for the shop admin list pages mounted by the test
  router: Products, Categories, ShippingMethods, Carts.

  These confirm each LV mounts, renders its title, shows the empty state,
  and surfaces a seeded row. They are intentionally light. None of these
  LVs gate `mount/3` on `Shop.enabled?()`, so no global settings are
  required — keeping them `async: true`.
  """

  use PhoenixKitEcommerce.LiveCase, async: true

  alias PhoenixKitEcommerce, as: Shop

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope)}
  end

  describe "Products" do
    test "mounts and shows the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/shop/products")
      assert html =~ "Products"
      assert html =~ "No products found"
    end

    test "renders a seeded product", %{conn: conn} do
      {:ok, _product} =
        Shop.create_product(%{
          "title" => %{"en" => "Smoke Test Widget"},
          "price" => Decimal.new("12.00"),
          "status" => "active"
        })

      {:ok, _view, html} = live(conn, "/en/admin/shop/products")
      assert html =~ "Smoke Test Widget"
    end

    # The list state lives in the query string, so every filter is free text
    # until it is checked. `category_uuid` goes into `where p.category_uuid ==
    # ^uuid`, where Ecto raises Ecto.Query.CastError on a non-UUID — a crashed
    # LiveView for anyone who edits the address bar. It must fall back to an
    # unfiltered list instead.
    test "a malformed ?category= renders unfiltered rather than crashing", %{conn: conn} do
      {:ok, _product} =
        Shop.create_product(%{
          "title" => %{"en" => "Uncategorised Widget"},
          "price" => Decimal.new("12.00"),
          "status" => "active"
        })

      {:ok, _view, html} = live(conn, "/en/admin/shop/products?category=not-a-uuid")
      assert html =~ "Uncategorised Widget"
    end
  end

  describe "Categories" do
    test "mounts and shows the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/shop/categories")
      assert html =~ "Categories"
      assert html =~ "No categories found"
    end

    test "renders a seeded category", %{conn: conn} do
      {:ok, _cat} = Shop.create_category(%{"name" => %{"en" => "Smoke Category"}})

      {:ok, _view, html} = live(conn, "/en/admin/shop/categories")
      assert html =~ "Smoke Category"
    end

    # Same story as ?category= on the products list: `parent_uuid` reaches
    # `where c.parent_uuid == ^uuid` and raises on anything that is not a
    # UUID. "root" is the one legitimate non-UUID value.
    test "a malformed ?parent= renders unfiltered rather than crashing", %{conn: conn} do
      {:ok, _cat} = Shop.create_category(%{"name" => %{"en" => "Root Category"}})

      {:ok, _view, html} = live(conn, "/en/admin/shop/categories?parent=not-a-uuid")
      assert html =~ "Root Category"

      {:ok, _view, root_html} = live(conn, "/en/admin/shop/categories?parent=root")
      assert root_html =~ "Root Category"
    end
  end

  describe "ShippingMethods" do
    test "mounts and shows the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/shop/shipping")
      assert html =~ "Shipping Methods"
      assert html =~ "No shipping methods"
    end

    test "renders a seeded shipping method", %{conn: conn} do
      {:ok, _method} =
        Shop.create_shipping_method(%{"name" => "Smoke Courier", "price" => Decimal.new("9.00")})

      {:ok, _view, html} = live(conn, "/en/admin/shop/shipping")
      assert html =~ "Smoke Courier"
    end
  end

  describe "Carts" do
    test "mounts and shows the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/shop/carts")
      assert html =~ "Carts"
      assert html =~ "No carts found"
    end

    test "renders a seeded guest cart", %{conn: conn} do
      session = "smoke-cart-abcdef0123456789"
      {:ok, _cart} = Shop.create_cart(session_id: session)

      {:ok, _view, html} = live(conn, "/en/admin/shop/carts")
      # The carts list slices the session id to the first 16 chars.
      assert html =~ String.slice(session, 0, 16)
    end
  end
end
