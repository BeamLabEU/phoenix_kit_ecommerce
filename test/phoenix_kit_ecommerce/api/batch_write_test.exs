defmodule PhoenixKitEcommerce.API.BatchWriteTest do
  @moduledoc """
  `Batch.write/3` against a real catalogue: the rows that change are written
  in one catalogue batch, the answer says `updated` or `unchanged` as the
  catalogue does, and only a write that changed something clears the
  storefront's cache.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api

  alias PhoenixKitEcommerce.API.Batch
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
end
