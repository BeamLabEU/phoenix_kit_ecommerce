defmodule PhoenixKitEcommerce.API.LoaderCatalogueTest do
  @moduledoc """
  `API.Loader` on the Catalogue source: the raw item statuses the view-struct
  hides, categories hidden by shop status or deleted, and an archived catalogue.

  `async: false`: `Query.catalogue_uuid/0` resolves the shop's catalogue by name
  across the whole test database.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query

  test "maps the six item states onto the three visibility states" do
    catalogue = catalogue_source!()

    items = %{
      listed: catalogue_item!(catalogue, "Active"),
      inactive: catalogue_item!(catalogue, "Inactive", %{status: "inactive"}),
      deleted: catalogue_item!(catalogue, "Deleted", %{status: "deleted"}),
      discontinued: catalogue_item!(catalogue, "Discontinued", %{status: "discontinued"}),
      draft: catalogue_item!(catalogue, "Draft", %{data: shop_data("draft")}),
      archived: catalogue_item!(catalogue, "Archived", %{data: shop_data("archived")})
    }

    records = items |> Map.values() |> Enum.map(& &1.uuid) |> Loader.load()
    state = fn key -> records[items[key].uuid].state end

    assert state.(:listed) == :listed
    assert state.(:inactive) == :hidden
    assert state.(:deleted) == :hidden
    assert state.(:discontinued) == :discontinued
    assert state.(:draft) == :hidden
    assert state.(:archived) == :discontinued
  end

  test "a category hidden by its shop status hides its products; unlisted does not" do
    catalogue = catalogue_source!()
    hidden = catalogue_category!(catalogue, "Hidden", %{data: shop_data("hidden")})
    unlisted = catalogue_category!(catalogue, "Unlisted", %{data: shop_data("unlisted")})

    in_hidden = catalogue_item!(catalogue, "In hidden", %{category_uuid: hidden.uuid})
    in_unlisted = catalogue_item!(catalogue, "In unlisted", %{category_uuid: unlisted.uuid})

    records = Loader.load([in_hidden.uuid, in_unlisted.uuid])

    assert records[in_hidden.uuid].state == :hidden
    assert records[in_unlisted.uuid].state == :listed
  end

  # A separate test, so that a broken fixture here can never hide the
  # hidden/unlisted assertions above.
  test "a category deleted in the catalogue hides its products (after a stray write)" do
    catalogue = catalogue_source!()
    deleted = catalogue_category!(catalogue, "Deleted")
    in_deleted = catalogue_item!(catalogue, "In deleted", %{category_uuid: deleted.uuid})

    assert Loader.load([in_deleted.uuid])[in_deleted.uuid].state == :listed

    :ok = delete_category_directly!(deleted)

    assert Loader.load([in_deleted.uuid])[in_deleted.uuid].state == :hidden
  end

  test "an archived catalogue hides every product" do
    catalogue = catalogue_source!()
    item = catalogue_item!(catalogue, "Vase")

    assert Loader.load([item.uuid])[item.uuid].state == :listed

    {:ok, _} = Catalogue.update_catalogue(catalogue, %{status: "archived"})

    assert Loader.load([item.uuid])[item.uuid].state == :hidden
    refute Loader.catalogue_listed?()
  end

  test "all_ids/0 lists every item of the shop catalogue, whatever its status" do
    catalogue = catalogue_source!()
    a = catalogue_item!(catalogue, "A")
    b = catalogue_item!(catalogue, "B", %{status: "deleted"})

    assert {:ok, ids} = Loader.all_ids()
    assert Enum.sort(ids) == Enum.sort([a.uuid, b.uuid])
    assert Loader.shop_catalogue_uuid() == catalogue.uuid
  end

  test "all_ids/0 reports a missing shop catalogue instead of an empty shop" do
    set_product_source!("catalogue")

    assert Loader.all_ids() == {:error, :no_catalogue}
    assert Loader.shop_catalogue_uuid() == nil
  end

  test "item_ids_in_categories/1 reads the catalogue's items" do
    catalogue = catalogue_source!()
    category = catalogue_category!(catalogue, "Vases")
    inside = catalogue_item!(catalogue, "Inside", %{category_uuid: category.uuid})
    _outside = catalogue_item!(catalogue, "Outside")

    assert Loader.item_ids_in_categories([category.uuid]) == [inside.uuid]
  end

  test "products_for_items/2 keeps the order and builds the same views as list_products_by_ids/1" do
    catalogue = catalogue_source!()
    first = catalogue_item!(catalogue, "First")
    second = catalogue_item!(catalogue, "Second")
    ids = [second.uuid, first.uuid]

    items = Query.list_items_by_uuids(ids)
    products = CatalogueSource.products_for_items(items, language: "en")

    assert Enum.map(products, & &1.uuid) == ids

    assert Enum.map(products, &{&1.uuid, &1.title}) ==
             ids |> CatalogueSource.list_products_by_ids() |> Enum.map(&{&1.uuid, &1.title})
  end
end
