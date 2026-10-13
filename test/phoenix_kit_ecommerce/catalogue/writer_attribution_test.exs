defmodule PhoenixKitEcommerce.Catalogue.WriterAttributionTest do
  @moduledoc """
  Prerequisite P3 end to end, against a real catalogue that has the admin
  API's write options: a Shopify sync write names itself in the item's change
  log, and a sync that read an item before someone else wrote to it does not
  overwrite that write (decision D4: last write wins per field).

  Needs the catalogue's phase 2a: `:catalogue_api`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api

  alias PhoenixKitEcommerce.API.{SetAvailability, SetPrices}
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.Catalogue.Writer

  setup do
    catalogue = F.shop_catalogue!()

    item =
      F.item!(catalogue, %{
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{
            "shop_status" => "active",
            "vendor" => "Old vendor",
            "shopify" => %{"handle" => "mug", "product_id" => "9001"}
          }
        }
      })

    %{item: item, ctx: F.ctx(F.user!())}
  end

  test "a sync write names the sync in the change log and shows the data it changed", %{
    item: item
  } do
    assert {:ok, _} = Writer.update_from_shopify(item, %{vendor: "New vendor"}, "en")

    entry =
      assert_activity_logged("item.updated",
        resource_uuid: item.uuid,
        metadata_has: %{"via" => "shopify_sync"}
      )

    assert inspect(entry.metadata["changes"]) =~ "vendor"
  end

  test "a sync that read the item before an API write does not overwrite that write",
       %{item: item, ctx: ctx} do
    stale = item

    assert {:ok, _} =
             SetPrices.run(
               %{
                 "items" => [
                   %{"ref" => %{"id" => item.uuid}, "compare_at" => "55.00", "price" => "120.00"}
                 ]
               },
               ctx
             )

    assert {:ok, _} =
             SetAvailability.run(
               %{"items" => [%{"ref" => %{"id" => item.uuid}, "made_to_order" => true}]},
               ctx
             )

    # the sync still holds the item as it was before both writes
    assert {:ok, _} = Writer.update_from_shopify(stale, %{vendor: "New vendor"}, "en")

    reloaded = F.reload!(item)
    ecommerce = reloaded.data["ecommerce"]

    assert ecommerce["vendor"] == "New vendor"
    assert ecommerce["compare_at_price"] == "55.00"
    assert ecommerce["made_to_order"] == true
    assert ecommerce["shopify"]["product_id"] == "9001"
    assert Decimal.equal?(reloaded.base_price, Decimal.new("120.00"))
  end

  test "the other direction: an API write keeps what the sync wrote", %{item: item, ctx: ctx} do
    assert {:ok, _} =
             Writer.update_from_shopify(item, %{vendor: "Synced", tags: ["a", "b"]}, "en")

    assert {:ok, _} =
             SetPrices.run(
               %{"items" => [%{"ref" => %{"id" => item.uuid}, "compare_at" => "9.00"}]},
               ctx
             )

    ecommerce = F.reload!(item).data["ecommerce"]
    assert ecommerce["vendor"] == "Synced"
    assert ecommerce["tags"] == ["a", "b"]
    assert ecommerce["compare_at_price"] == "9.00"
    assert ecommerce["shopify"]["handle"] == "mug"
  end

  test "a price-only sync that read the item before an API write keeps that write", %{
    item: item,
    ctx: ctx
  } do
    stale = item

    assert {:ok, _} =
             SetPrices.run(
               %{
                 "items" => [%{"ref" => %{"id" => item.uuid}, "compare_at" => "55.00"}]
               },
               ctx
             )

    assert {:ok, _} =
             SetAvailability.run(
               %{"items" => [%{"ref" => %{"id" => item.uuid}, "visibility" => "archived"}]},
               ctx
             )

    # a column-only change: nothing in `data` is the sync's to write
    assert {:ok, _} = Writer.update_from_shopify(stale, %{price: Decimal.new("20.00")}, "en")

    reloaded = F.reload!(item)
    ecommerce = reloaded.data["ecommerce"]

    assert Decimal.equal?(reloaded.base_price, Decimal.new("20.00"))
    assert ecommerce["compare_at_price"] == "55.00"
    assert ecommerce["shop_status"] == "archived"
    assert ecommerce["shopify"]["product_id"] == "9001"
  end

  test "a default the sync did not mean to write is not stored" do
    bare =
      F.item!(F.shop_catalogue!(), %{
        data: %{"_primary_language" => "en", "ecommerce" => %{"vendor" => "Old vendor"}}
      })

    assert {:ok, _} = Writer.update_from_shopify(bare, %{vendor: "New vendor"}, "en")

    ecommerce = F.reload!(bare).data["ecommerce"]
    assert ecommerce["vendor"] == "New vendor"
    refute Map.has_key?(ecommerce, "shop_status")
    refute Map.has_key?(ecommerce, "made_to_order")
  end

  test "image ids written by the media sync keep their own attribution", %{item: item} do
    product = %{"id" => 9001, "images" => []}

    assert {:ok, _} = Writer.sync_images(item, product, user_uuid: F.user!().uuid)

    assert_activity_logged("item.updated",
      resource_uuid: item.uuid,
      metadata_has: %{"via" => "shopify_sync"}
    )
  end
end
