defmodule PhoenixKitEcommerce.Search.IndexerCatalogueTest do
  @moduledoc """
  The indexer over catalogue items: the four item states, a category rename
  reaching the whole subtree, and a rebuild that cannot resolve the catalogue.

  `async: false`: the shop's catalogue is found by name across the database.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Test.Repo

  defp titles, do: Repo.all(from(e in Entry, order_by: e.title, select: e.title))

  test "only an active item with an active shop status is indexed" do
    catalogue = catalogue_source!()

    catalogue_item!(catalogue, "Listed")
    catalogue_item!(catalogue, "Inactive", %{status: "inactive"})
    catalogue_item!(catalogue, "Deleted", %{status: "deleted"})
    catalogue_item!(catalogue, "Discontinued", %{status: "discontinued"})
    catalogue_item!(catalogue, "Draft", %{data: shop_data("draft")})
    catalogue_item!(catalogue, "Archived", %{data: shop_data("archived")})

    assert {:ok, %{products: 6, indexed: 1, removed: 0}} = Indexer.rebuild()
    assert titles() == ["Listed"]
  end

  test "a category rename reaches every product of its subtree after a subtree reindex" do
    catalogue = catalogue_source!()
    root = catalogue_category!(catalogue, "Home")
    leaf = catalogue_category!(catalogue, "Vases", %{parent_uuid: root.uuid})
    item = catalogue_item!(catalogue, "Red Vase", %{category_uuid: leaf.uuid})

    {:ok, _} = Indexer.reindex_items([item.uuid])

    assert [%{category_path: ["Home", "Vases"]}] =
             Repo.all(from(e in Entry, select: %{category_path: e.category_path}))

    {:ok, _} = Catalogue.update_category(root, %{name: "Shop"})

    subtree = Loader.subtree_uuids(root.uuid, Loader.categories())
    ids = Loader.item_ids_in_categories(subtree)
    assert ids == [item.uuid]

    {:ok, _} = Indexer.reindex_items(ids)

    assert [%{category_path: ["Shop", "Vases"]}] =
             Repo.all(from(e in Entry, select: %{category_path: e.category_path}))
  end

  test "rebuild/0 changes nothing when the shop catalogue cannot be resolved" do
    catalogue = catalogue_source!()
    catalogue_item!(catalogue, "Red Vase")
    assert {:ok, %{indexed: 1}} = Indexer.rebuild()

    # The shop finds its catalogue by name; renaming it makes it unresolvable.
    {:ok, _} = Catalogue.update_catalogue(catalogue, %{name: "somebody else"})

    assert Indexer.rebuild() == {:error, :no_catalogue}
    assert titles() == ["Red Vase"]
  end

  test "reindex_items/1 changes nothing when the shop catalogue cannot be resolved" do
    catalogue = catalogue_source!()
    item = catalogue_item!(catalogue, "Red Vase")
    assert {:ok, %{indexed: 1}} = Indexer.rebuild()

    {:ok, _} = Catalogue.update_catalogue(catalogue, %{name: "somebody else"})

    assert {:ok, %{indexed: 0, removed: 0}} = Indexer.reindex_items([item.uuid])
    assert titles() == ["Red Vase"]
  end

  test "an archived catalogue is a real change: the next rebuild lists nothing" do
    catalogue = catalogue_source!()
    catalogue_item!(catalogue, "Red Vase")
    {:ok, _} = Indexer.rebuild()
    assert titles() == ["Red Vase"]

    {:ok, _} = Catalogue.update_catalogue(catalogue, %{status: "archived"})

    assert {:ok, %{indexed: 0, removed: 1}} = Indexer.rebuild()
    assert titles() == []
  end
end
