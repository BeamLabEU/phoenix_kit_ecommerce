defmodule PhoenixKitEcommerce.Shopify.CollectionSyncTest do
  @moduledoc """
  `PhoenixKitEcommerce.Shopify.CollectionSync.run/1` (Block 7 Task 4,
  `docs/superpowers/plans/2026-09-06-block7-shopify-media-collections.md`):
  Shopify collections mapped onto catalogue categories with order
  preserved, and catalogue items placed into the right category at the
  right position from the collections' product lists.

  Needs `phoenix_kit_catalogue` loaded (real `Catalogue.create_category/2`
  / `update_category/3` / `update_item/2` against a live catalogue) —
  tagged `:catalogue` and excluded via `test_helper.exs` whenever the
  optional dependency isn't present, same as `writer_variants_test.exs`/
  `writer_images_test.exs`. `async: false`: flips the process-wide
  `shop_product_source` config key. `opts[:client]` is a stub module
  (this test's own `@stub`) — no real HTTP, per Global Constraints.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.CollectionSync
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} =
      Catalogue.create_catalogue(%{name: "collection-sync-#{System.unique_integer([:positive])}"})

    %{catalogue: catalogue}
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  defp create_item(catalogue_uuid, name, product_id, attrs \\ %{}) do
    {:ok, item} =
      Catalogue.create_item(
        Map.merge(
          %{
            catalogue_uuid: catalogue_uuid,
            name: name,
            base_price: Decimal.new("10.00"),
            status: "active",
            data: %{
              "ecommerce" => %{
                "shop_status" => "active",
                "shopify" => %{"product_id" => to_string(product_id)}
              }
            }
          },
          attrs
        )
      )

    item
  end

  # Two Shopify collections:
  #   - "frames" (id 1, position 0) — matches a pre-existing category by
  #     handle, product 111 already lives there from a previous run.
  #   - "gifts" (id 2, position 1) — no local category, gets created;
  #     product 111 is ALSO listed here (should stay in Frames); product
  #     222 is new and gets assigned to Gifts; product 999 is unknown.
  defmodule Stub do
    @moduledoc false

    def fetch_collections(_opts) do
      {:ok,
       [
         %{
           "id" => 1,
           "handle" => "frames",
           "title" => "Frames",
           "kind" => "custom",
           "position" => 0
         },
         %{
           "id" => 2,
           "handle" => "gifts",
           "title" => "Gifts",
           "kind" => "custom",
           "position" => 1
         }
       ]}
    end

    def fetch_collection_product_ids(1, _opts), do: {:ok, [111, 999]}
    def fetch_collection_product_ids(2, _opts), do: {:ok, [111, 222]}
  end

  describe "run/1 — legacy source" do
    test "is a no-op returning :catalogue_source_inactive" do
      assert CollectionSync.run(client: Stub, catalogue_uuid: Ecto.UUID.generate()) ==
               {:error, :catalogue_source_inactive}
    end
  end

  describe "run/1 — catalogue source" do
    setup do
      set_product_source("catalogue")
      :ok
    end

    test "requires a catalogue_uuid" do
      assert CollectionSync.run(client: Stub) == {:error, :missing_catalogue_uuid}
    end

    test "matches an existing category by handle and updates its position", %{
      catalogue: catalogue
    } do
      {:ok, frames} =
        Catalogue.create_category(%{
          name: "Frames (old title)",
          catalogue_uuid: catalogue.uuid,
          slug: %{"en" => "frames"},
          position: 9
        })

      create_item(catalogue.uuid, "Frame A", 111)
      create_item(catalogue.uuid, "Gift A", 222)

      assert {:ok, result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)
      assert result.categories_matched == 1
      assert result.categories_created == 1

      updated_frames = Catalogue.get_category!(frames.uuid)
      assert updated_frames.position == 0
      assert updated_frames.data["ecommerce"]["shopify"]["collection_id"] == "1"
    end

    test "creates a category for a collection with no local match, position = collection position",
         %{catalogue: catalogue} do
      create_item(catalogue.uuid, "Frame A", 111)

      assert {:ok, _result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)

      [gifts] =
        catalogue.uuid
        |> Catalogue.list_categories_metadata_for_catalogue()
        |> Enum.filter(&(&1.name == "Gifts"))

      assert gifts.position == 1
      assert gifts.data["ecommerce"]["shopify"]["collection_id"] == "2"
      assert gifts.parent_uuid == nil
      assert gifts.slug["en"] == "gifts"
    end

    test "assigns an unassigned item to its collection's category, at its list position", %{
      catalogue: catalogue
    } do
      item = create_item(catalogue.uuid, "Gift A", 222)
      assert item.category_uuid == nil

      assert {:ok, result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)
      assert result.items_assigned == 1
      assert result.items_repositioned == 1

      [gifts] =
        catalogue.uuid
        |> Catalogue.list_categories_metadata_for_catalogue()
        |> Enum.filter(&(&1.name == "Gifts"))

      updated = Catalogue.get_item!(item.uuid)
      assert updated.category_uuid == gifts.uuid
      assert updated.position == 1
    end

    test "a product listed in two collections keeps the category it already had", %{
      catalogue: catalogue
    } do
      {:ok, frames} =
        Catalogue.create_category(%{
          name: "Frames",
          catalogue_uuid: catalogue.uuid,
          slug: %{"en" => "frames"},
          position: 0
        })

      item =
        create_item(catalogue.uuid, "Frame A", 111, %{category_uuid: frames.uuid, position: 5})

      assert {:ok, result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)

      updated = Catalogue.get_item!(item.uuid)
      assert updated.category_uuid == frames.uuid
      # Frames is collection id 1, product 111 is at index 0 in its list.
      assert updated.position == 0
      assert result.items_repositioned == 1
      assert result.items_assigned == 0
    end

    test "a product id with no matching local item is reported unmatched", %{catalogue: catalogue} do
      create_item(catalogue.uuid, "Frame A", 111)
      create_item(catalogue.uuid, "Gift A", 222)

      assert {:ok, result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)
      assert result.unmatched_products == [999]
    end

    test "a second run against the same fixture is idempotent", %{catalogue: catalogue} do
      create_item(catalogue.uuid, "Frame A", 111)
      create_item(catalogue.uuid, "Gift A", 222)

      assert {:ok, _first} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)
      assert {:ok, second} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)

      assert second.categories_created == 0
      assert second.categories_matched == 2
      assert second.items_assigned == 0
      assert second.items_repositioned == 0
      assert second.unmatched_products == [999]
    end

    test "a category with no matching collection is left untouched", %{catalogue: catalogue} do
      {:ok, other} =
        Catalogue.create_category(%{
          name: "Other 3d",
          catalogue_uuid: catalogue.uuid,
          position: 3
        })

      assert {:ok, _result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)

      untouched = Catalogue.get_category!(other.uuid)
      assert untouched.position == 3
      assert untouched.data == %{}
    end
  end
end
