defmodule PhoenixKitEcommerce.Web.RelatedProductsCatalogueTest do
  @moduledoc """
  The related-products block of the product page and the cross-sells of the
  cart, over the catalogue product source.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.RelatedProducts
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    %{catalogue: catalogue}
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config |> ShopConfig.changeset(%{value: %{"value" => value}}) |> Repo.update!()
    end
  end

  defp item!(catalogue, name, attrs \\ %{}, ecommerce \\ %{}) do
    {:ok, item} =
      Catalogue.create_item(
        Map.merge(
          %{
            catalogue_uuid: catalogue.uuid,
            name: name,
            base_price: Decimal.new("9.00"),
            status: "active",
            slug: %{"en-US" => String.downcase(String.replace(name, " ", "-"))},
            data: %{"ecommerce" => Map.merge(%{"shop_status" => "active"}, ecommerce)}
          },
          attrs
        )
      )

    item
  end

  test "the product page lists the picked items in order and skips retired ones", %{
    conn: conn,
    catalogue: catalogue
  } do
    a = item!(catalogue, "Calendar item")
    b = item!(catalogue, "Tote bag item")
    draft = item!(catalogue, "Draft item", %{}, %{"shop_status" => "draft"})
    retired = item!(catalogue, "Retired item", %{status: "inactive"})

    main =
      item!(catalogue, "Shirt item", %{}, %{
        "related_product_uuids" => [b.uuid, draft.uuid, a.uuid, retired.uuid]
      })

    {:ok, view, html} = live(conn, "/shop/product/#{main.slug["en-US"]}")

    assert has_element?(view, "#related-products")
    assert html =~ "You may also like"
    {bag, _} = :binary.match(html, "Tote bag item")
    {calendar, _} = :binary.match(html, "Calendar item")
    assert bag < calendar
    refute html =~ "Draft item"
    refute html =~ "Retired item"
  end

  test "a page with no list renders no block", %{conn: conn, catalogue: catalogue} do
    main = item!(catalogue, "Lonely item")
    {:ok, view, _html} = live(conn, "/shop/product/#{main.slug["en-US"]}")
    refute has_element?(view, "#related-products")
  end

  test "the category fallback lists the item's category siblings", %{
    conn: conn,
    catalogue: catalogue
  } do
    {:ok, category} = Catalogue.create_category(%{name: "Shelf", catalogue_uuid: catalogue.uuid})
    sibling = item!(catalogue, "Shelf sibling", %{category_uuid: category.uuid})
    main = item!(catalogue, "Shelf main", %{category_uuid: category.uuid})

    {:ok, view, _html} = live(conn, "/shop/product/#{main.slug["en-US"]}")
    refute has_element?(view, "#related-products")

    previous = Settings.get_setting("shop_related_fallback", "")
    Settings.update_setting("shop_related_fallback", "category")
    on_exit(fn -> Settings.update_setting("shop_related_fallback", previous) end)

    {:ok, view, html} = live(conn, "/shop/product/#{main.slug["en-US"]}")
    assert has_element?(view, "#related-products")
    assert html =~ sibling.name
    refute has_element?(view, "#related-products a[href$='#{main.slug["en-US"]}']")
  end

  test "an item is never in its own block", %{conn: conn, catalogue: catalogue} do
    main = item!(catalogue, "Self item")

    {:ok, _} =
      Catalogue.update_item(main, %{
        data: %{
          "ecommerce" => %{"shop_status" => "active", "related_product_uuids" => [main.uuid]}
        }
      })

    {:ok, view, _html} = live(conn, "/shop/product/#{main.slug["en-US"]}")
    refute has_element?(view, "#related-products")
  end

  test "the cart offers the cross-sells of the items in it", %{conn: conn, catalogue: catalogue} do
    extra = item!(catalogue, "Cart extra")
    shirt = item!(catalogue, "Cart shirt", %{}, %{"cross_sell_product_uuids" => [extra.uuid]})

    session_id = "cat-xsell-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    [product] = Shop.list_products_by_ids([shirt.uuid])
    {:ok, _} = Shop.add_to_cart(cart, product, 1)

    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})
    {:ok, view, html} = live(conn, "/cart")

    assert has_element?(view, "#cross-sell-#{extra.uuid}")
    assert html =~ "Add to your order"

    view |> element("#cross-sell-#{extra.uuid} button") |> render_click()
    refute has_element?(view, "#cross-sell-#{extra.uuid}")

    lines = Shop.get_cart!(cart.uuid).items
    assert extra.uuid in Enum.map(lines, & &1.metadata["catalogue_item_uuid"])
  end

  test "the view carries both lists in its metadata", %{catalogue: catalogue} do
    a = item!(catalogue, "Listed a")

    main =
      item!(catalogue, "Listing main", %{}, %{
        "related_product_uuids" => [a.uuid],
        "cross_sell_product_uuids" => [a.uuid]
      })

    [product] = Shop.list_products_by_ids([main.uuid])
    assert RelatedProducts.uuids(product, :related) == [a.uuid]
    assert RelatedProducts.uuids(product, :cross_sell) == [a.uuid]
  end

  test "Add rechecks a catalogue category hidden after the cart opened", %{
    conn: conn,
    catalogue: catalogue
  } do
    {:ok, category} =
      Catalogue.create_category(%{name: "Changing shelf", catalogue_uuid: catalogue.uuid})

    extra = item!(catalogue, "Changing extra", %{category_uuid: category.uuid})
    shirt = item!(catalogue, "Changing shirt", %{}, %{"cross_sell_product_uuids" => [extra.uuid]})

    session_id = "cat-changing-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    [product] = Shop.list_products_by_ids([shirt.uuid])
    {:ok, _} = Shop.add_to_cart(cart, product, 1)
    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})
    {:ok, view, _html} = live(conn, "/cart")
    assert has_element?(view, "#cross-sell-#{extra.uuid} button")

    {:ok, _} =
      Catalogue.update_category(category, %{data: %{"ecommerce" => %{"shop_status" => "hidden"}}})

    render_hook(view, "add_cross_sell", %{"uuid" => extra.uuid})

    assert length(Shop.get_cart!(cart.uuid).items) == 1
    refute has_element?(view, "#cross-sell-#{extra.uuid}")
  end

  describe "visibility of listed items" do
    alias PhoenixKitEcommerce.ProductSource.Catalogue.Query

    defp category!(catalogue, name, shop_status) do
      {:ok, category} =
        Catalogue.create_category(%{
          name: name,
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"shop_status" => shop_status}}
        })

      category
    end

    test "an item of a hidden category is not listed, one of an unlisted category is", %{
      catalogue: catalogue
    } do
      hidden = category!(catalogue, "Hidden shelf", "hidden")
      unlisted = category!(catalogue, "Unlisted shelf", "unlisted")

      in_hidden = item!(catalogue, "In hidden", %{category_uuid: hidden.uuid})
      in_unlisted = item!(catalogue, "In unlisted", %{category_uuid: unlisted.uuid})
      loose = item!(catalogue, "Loose item")
      draft = item!(catalogue, "Draft one", %{}, %{"shop_status" => "draft"})

      uuids = [in_hidden.uuid, draft.uuid, in_unlisted.uuid, loose.uuid]

      assert Enum.map(Query.list_listed_items_by_uuids(uuids), & &1.uuid) ==
               [in_unlisted.uuid, loose.uuid]

      assert Query.list_listed_items_by_uuids([]) == []
    end
  end

  test "a product whose category has a required option gets a link, not an Add button", %{
    conn: conn,
    catalogue: catalogue
  } do
    size = %{
      "key" => "size",
      "label" => "Size",
      "type" => "select",
      "options" => ["S", "L"],
      "required" => true,
      "affects_price" => true,
      "modifier_type" => "fixed",
      "price_modifiers" => %{"S" => "0", "L" => "5"}
    }

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Sized shelf",
        catalogue_uuid: catalogue.uuid,
        data: %{"ecommerce" => %{"option_schema" => [size]}}
      })

    sized = item!(catalogue, "Sized item", %{category_uuid: category.uuid})
    shirt = item!(catalogue, "Option shirt", %{}, %{"cross_sell_product_uuids" => [sized.uuid]})

    session_id = "cat-opt-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    [product] = Shop.list_products_by_ids([shirt.uuid])
    {:ok, _} = Shop.add_to_cart(cart, product, 1)

    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})
    {:ok, view, _html} = live(conn, "/cart")

    assert has_element?(view, "#cross-sell-#{sized.uuid} a")
    refute has_element?(view, "#cross-sell-#{sized.uuid} button")

    render_hook(view, "add_cross_sell", %{"uuid" => sized.uuid})
    assert length(Shop.get_cart!(cart.uuid).items) == 1
  end
end
