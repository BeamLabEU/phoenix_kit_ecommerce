defmodule PhoenixKitEcommerce.API.SetAvailabilityTest do
  @moduledoc """
  `ecommerce.set_availability` against a real catalogue: publishing and
  hiding, the made-to-order flag, the refusal to publish a product with no
  price, and agreement with what the storefront shows.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api

  alias PhoenixKitEcommerce.API.{GetPrices, SetAvailability}
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.StorefrontCache

  setup do
    catalogue = F.shop_catalogue!()
    user = F.user!()
    %{catalogue: catalogue, user: user, ctx: F.ctx(user)}
  end

  defp run(items, ctx), do: SetAvailability.run(%{"items" => items}, ctx)

  defp draft_item(catalogue, attrs \\ %{}) do
    F.item!(
      catalogue,
      Map.merge(
        %{data: %{"_primary_language" => "en", "ecommerce" => %{"shop_status" => "draft"}}},
        attrs
      )
    )
  end

  defp visible?(item, ctx) do
    {:ok, %{"results" => [row]}} = GetPrices.run(%{"refs" => [%{"id" => item.uuid}]}, ctx)
    row["shop_status_visible"]
  end

  describe "the storefront cache" do
    setup do
      start_supervised!(PhoenixKit.Cache.Registry)
      [spec] = StorefrontCache.children()
      start_supervised!(spec)
      :ok
    end

    test "a write clears it; a dry run and an unchanged row leave it", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = draft_item(catalogue)
      row = %{"ref" => %{"id" => item.uuid}, "visibility" => "active"}

      :stale = StorefrontCache.fetch(:probe, fn -> :stale end)

      assert {:preview, _preview, _fingerprint} = run([row], %{ctx | dry_run?: true})
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale

      assert {:ok, %{"summary" => %{"updated" => 1}}} = run([row], ctx)
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh

      StorefrontCache.clear()
      :stale = StorefrontCache.fetch(:probe, fn -> :stale end)
      assert {:ok, %{"summary" => %{"unchanged" => 1}}} = run([row], ctx)
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale
    end
  end

  test "publishes a draft product and hides it again", %{catalogue: catalogue, ctx: ctx} do
    item = draft_item(catalogue)
    refute visible?(item, ctx)

    assert {:ok, %{"results" => [%{"action" => "updated"} = result]}} =
             run([%{"ref" => %{"id" => item.uuid}, "visibility" => "active"}], ctx)

    assert result["changes"] == %{"visibility" => %{"from" => "draft", "to" => "active"}}
    assert visible?(item, ctx)

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run([%{"ref" => %{"id" => item.uuid}, "visibility" => "archived"}], ctx)

    refute visible?(item, ctx)
  end

  test "visibility and made_to_order are written independently and leave the rest alone",
       %{catalogue: catalogue, ctx: ctx} do
    item =
      draft_item(catalogue, %{
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{
            "shop_status" => "draft",
            "compare_at_price" => "20.00",
            "shopify" => %{"product_id" => "7"}
          }
        }
      })

    assert {:ok, _} = run([%{"ref" => %{"id" => item.uuid}, "made_to_order" => true}], ctx)

    ecommerce = F.reload!(item).data["ecommerce"]
    assert ecommerce["made_to_order"] == true
    assert ecommerce["shop_status"] == "draft"
    assert ecommerce["compare_at_price"] == "20.00"
    assert ecommerce["shopify"] == %{"product_id" => "7"}
  end

  test "a product with no price cannot be published; a price on request can", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    no_price = draft_item(catalogue, %{base_price: nil})

    on_request =
      draft_item(catalogue, %{
        base_price: nil,
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{"shop_status" => "draft", "price_on_request" => true}
        }
      })

    assert {:ok, %{"results" => [refused, allowed]}} =
             run(
               [
                 %{"ref" => %{"id" => no_price.uuid}, "visibility" => "active"},
                 %{"ref" => %{"id" => on_request.uuid}, "visibility" => "active"}
               ],
               ctx
             )

    assert refused["action"] == "error"
    assert refused["error"]["code"] == "validation_failed"
    assert allowed["action"] == "updated"

    refute visible?(no_price, ctx)
    assert visible?(on_request, ctx)
  end

  test "a product with no shop_status already counts as active, so publishing it changes nothing",
       %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue, %{data: %{"_primary_language" => "en"}})

    assert {:ok, %{"results" => [%{"action" => "unchanged"}]}} =
             run([%{"ref" => %{"id" => item.uuid}, "visibility" => "active"}], ctx)
  end

  test "an item the catalogue keeps inactive stays hidden, and the row says so", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    item = draft_item(catalogue, %{status: "inactive"})

    assert {:ok, %{"results" => [row]}} =
             run([%{"ref" => %{"id" => item.uuid}, "visibility" => "active"}], ctx)

    assert row["warnings"] == ["item_not_active"]
    refute visible?(item, ctx)
  end

  test "rows are independent and the dry run writes nothing", %{catalogue: catalogue, ctx: ctx} do
    item = draft_item(catalogue)

    rows = [
      %{"ref" => %{"sku" => "AV-NONE"}, "visibility" => "active"},
      %{"ref" => %{"id" => item.uuid}, "visibility" => "active"}
    ]

    assert {:preview, preview, fingerprint} = run(rows, %{ctx | dry_run?: true})
    assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert Enum.map(preview["rows"], & &1["action"]) == ["error", "update"]
    refute visible?(item, ctx)

    assert {:ok, %{"summary" => %{"error" => 1, "updated" => 1}}} = run(rows, ctx)
    assert visible?(item, ctx)
  end

  test "the change log names the key's owner and the tool", %{
    catalogue: catalogue,
    user: user,
    ctx: ctx
  } do
    item = draft_item(catalogue)
    assert {:ok, _} = run([%{"ref" => %{"id" => item.uuid}, "visibility" => "active"}], ctx)

    assert_activity_logged("item.updated",
      resource_uuid: item.uuid,
      actor_uuid: user.uuid,
      metadata_has: %{"via" => "api", "tool" => "ecommerce.set_availability"}
    )
  end

  test "the legacy source is refused", %{catalogue: catalogue, ctx: ctx} do
    item = draft_item(catalogue)
    F.put_config!("shop_product_source", "legacy")

    assert {:error, :unsupported_source, _detail, %{reason: "legacy_source"}} =
             run([%{"ref" => %{"id" => item.uuid}, "visibility" => "active"}], ctx)
  end
end
