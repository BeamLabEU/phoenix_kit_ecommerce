defmodule PhoenixKitEcommerce.API.Public.CatalogCatalogueTest do
  @moduledoc """
  `shop.get_products` over catalogue items: the four item states of the
  catalogue and the two shop statuses, row by row (spec 7.1).

  `async: false`: the shop's catalogue is found by name across the database.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce.API.Public.Catalog

  setup do
    disable_languages!()
    currencies!()
    :ok
  end

  test "inactive, deleted and draft items are not found; discontinued and archived ones are stubs" do
    catalogue = catalogue_source!()

    listed = catalogue_item!(catalogue, "Listed")
    inactive = catalogue_item!(catalogue, "Inactive", %{status: "inactive"})
    deleted = catalogue_item!(catalogue, "Deleted", %{status: "deleted"})
    discontinued = catalogue_item!(catalogue, "Discontinued", %{status: "discontinued"})
    draft = catalogue_item!(catalogue, "Draft", %{data: shop_data("draft")})
    archived = catalogue_item!(catalogue, "Archived", %{data: shop_data("archived")})

    ids = Enum.map([listed, inactive, deleted, discontinued, draft, archived], & &1.uuid)

    assert {:ok, out} = Catalog.get_products(%{"ids" => ids}, public_ctx())

    shape =
      Enum.map(out["results"], fn
        %{"product" => %{"status" => status}} -> status
        %{"error" => %{"code" => code}} -> code
      end)

    assert shape == [
             "active",
             "not_found",
             "not_found",
             "discontinued",
             "not_found",
             "discontinued"
           ]

    assert out["summary"] == %{"found" => 1, "discontinued" => 2, "not_found" => 3}

    stub = Enum.at(out["results"], 3)["product"]
    assert Map.keys(stub) |> Enum.sort() == ["id", "status", "title"]
  end

  test "a product in a hidden category is not found; in an unlisted one it is shown" do
    catalogue = catalogue_source!()
    hidden = catalogue_category!(catalogue, "Hidden", %{data: shop_data("hidden")})
    unlisted = catalogue_category!(catalogue, "Unlisted", %{data: shop_data("unlisted")})

    in_hidden = catalogue_item!(catalogue, "In hidden", %{category_uuid: hidden.uuid})
    in_unlisted = catalogue_item!(catalogue, "In unlisted", %{category_uuid: unlisted.uuid})

    assert {:ok, out} =
             Catalog.get_products(%{"ids" => [in_hidden.uuid, in_unlisted.uuid]}, public_ctx())

    assert out["summary"] == %{"found" => 1, "discontinued" => 0, "not_found" => 1}
    assert Enum.at(out["results"], 1)["product"]["id"] == in_unlisted.uuid
  end

  test "a product in a category deleted in the catalogue is not found (after a stray write)" do
    catalogue = catalogue_source!()
    deleted = catalogue_category!(catalogue, "Deleted")
    in_deleted = catalogue_item!(catalogue, "In deleted", %{category_uuid: deleted.uuid})

    assert {:ok, %{"summary" => %{"found" => 1}}} =
             Catalog.get_products(%{"ids" => [in_deleted.uuid]}, public_ctx())

    :ok = delete_category_directly!(deleted)

    assert {:ok, %{"summary" => %{"found" => 0, "not_found" => 1}}} =
             Catalog.get_products(%{"ids" => [in_deleted.uuid]}, public_ctx())
  end
end
