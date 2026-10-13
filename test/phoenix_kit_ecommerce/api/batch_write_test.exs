defmodule PhoenixKitEcommerce.API.BatchWriteTest do
  @moduledoc """
  `Batch.write/3` against a real catalogue: the rows that change are written
  in one catalogue batch, the answer says `updated` or `unchanged` as the
  catalogue does, and only a write that changed something clears the
  storefront's cache.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.{Batch, PricePlan}
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.StorefrontCache

  setup do
    start_supervised!(PhoenixKit.Cache.Registry)
    [spec] = StorefrontCache.children()
    start_supervised!(spec)

    catalogue = F.shop_catalogue!()
    %{catalogue: catalogue, ctx: F.ctx(F.user!())}
  end

  defp write_price(catalogue, item, price, ctx) do
    [row] = Batch.load([%{"ref" => %{"id" => item.uuid}}], catalogue.uuid)

    [row] =
      Batch.plan([row], fn _row ->
        {:ok,
         %{
           from: %{price: item.base_price},
           changes: %{"price" => %{"from" => "100.00", "to" => Decimal.to_string(price)}},
           changed?: true,
           dangerous?: false,
           warnings: [],
           attrs: %{base_price: price},
           owned_paths: []
         }}
      end)

    [written] = Batch.write([row], ctx, "ecommerce.set_prices")
    written
  end

  test "a changed row is stored, answered as updated and clears the storefront cache",
       %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)
    :stale = StorefrontCache.fetch(:probe, fn -> :stale end)

    row = write_price(catalogue, item, Decimal.new("120.00"), ctx)

    assert {:ok, _item} = row.result
    assert %{"results" => [%{"action" => "updated"}]} = Batch.render([row])
    assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("120.00"))
    assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh
  end

  test "a row the catalogue finds already up to date is unchanged and leaves the cache",
       %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)
    :stale = StorefrontCache.fetch(:probe, fn -> :stale end)

    row = write_price(catalogue, item, Decimal.new("100.00"), ctx)

    assert {:unchanged, _item} = row.result
    assert %{"results" => [%{"action" => "unchanged"}]} = Batch.render([row])
    assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale
  end

  describe "a row that owns one data path" do
    @shop_status_path ["ecommerce", "shop_status"]

    defp shop_status_item(catalogue) do
      F.item!(catalogue, %{
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{
            "shop_status" => "active",
            "shopify" => %{"product_id" => "100"},
            "price_modifiers" => %{"Size" => %{"S" => "1.00"}}
          }
        }
      })
    end

    # The plan of a row that sets `shop_status` to "hidden" and owns only that path.
    defp hide_plan do
      %{
        from: %{visibility: "active"},
        changes: %{"visibility" => %{"from" => "active", "to" => "hidden"}},
        changed?: true,
        dangerous?: false,
        warnings: [],
        attrs: %{data: %{"ecommerce" => %{"shop_status" => "hidden"}}},
        owned_paths: [@shop_status_path]
      }
    end

    defp planned_hide_row(catalogue, item) do
      [row] = Batch.load([%{"ref" => %{"id" => item.uuid}}], catalogue.uuid)
      [row] = Batch.plan([row], fn _row -> {:ok, hide_plan()} end)
      row
    end

    test "the values another writer stored since the row was read survive", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = shop_status_item(catalogue)
      row = planned_hide_row(catalogue, item)

      # A foreign writer (the Shopify sync) stores while the row is planned.
      {:ok, _} =
        Catalogue.update_item(F.reload!(item), %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{
              "shop_status" => "active",
              "shopify" => %{"product_id" => "200"},
              "price_modifiers" => %{"Size" => %{"S" => "1.00", "M" => "5.00"}}
            }
          }
        })

      assert [%{result: {:ok, _item}}] = Batch.write([row], ctx, "ecommerce.set_availability")

      ecommerce = F.reload!(item).data["ecommerce"]
      assert ecommerce["shop_status"] == "hidden"
      assert ecommerce["shopify"] == %{"product_id" => "200"}
      assert ecommerce["price_modifiers"] == %{"Size" => %{"S" => "1.00", "M" => "5.00"}}
    end

    test "the change log names the key owner, the tool and the request, as an automatic change",
         %{catalogue: catalogue, ctx: ctx} do
      item = shop_status_item(catalogue)
      row = planned_hide_row(catalogue, item)

      assert [%{result: {:ok, _item}}] = Batch.write([row], ctx, "ecommerce.set_availability")

      entry =
        assert_activity_logged("item.updated",
          resource_uuid: item.uuid,
          actor_uuid: ctx.actor.user_uuid,
          metadata_has: %{
            "via" => "api",
            "tool" => "ecommerce.set_availability",
            "key_prefix" => "a1b2c3d4",
            "request_id" => "req-test"
          }
        )

      assert entry.mode == "auto"

      assert entry.metadata["changes"]["data.ecommerce.shop_status"] ==
               %{"from" => "active", "to" => "hidden"}
    end
  end

  describe "option and value names with dots" do
    test "the preview and the result agree and the write lands on the right leaf",
         %{catalogue: catalogue, ctx: ctx} do
      item =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{
              "shop_status" => "active",
              "price_modifiers" => %{"a.b" => %{"c" => "1.00"}, "a" => %{"b.c" => "2.00"}}
            }
          }
        })

      [row] = Batch.load([%{"ref" => %{"id" => item.uuid}}], catalogue.uuid)

      [row] =
        Batch.plan([row], fn row ->
          PricePlan.plan(
            %{"price_modifiers" => %{"a.b" => %{"c" => "3.00"}, "a" => %{"b.c" => nil}}},
            row.item,
            pct: 30,
            sets: nil
          )
        end)

      assert %{"rows" => [%{"action" => "update"}]} = Batch.preview([row])

      [written] = Batch.write([row], ctx, "ecommerce.set_prices")

      assert %{"results" => [%{"action" => "updated"}]} = Batch.render([written])
      modifiers = F.reload!(item).data["ecommerce"]["price_modifiers"]
      assert modifiers == %{"a.b" => %{"c" => "3.00"}}
    end
  end
end
