defmodule PhoenixKitEcommerce.API.SetPricesTest do
  @moduledoc """
  `ecommerce.set_prices` against a real catalogue: the write, the rows that
  fail alone, the change log, the dry run and its fingerprint, and the
  danger check at its boundaries.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api
  @moduletag :core_confirm

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.API.{CatalogueWrites, PricePlan, SetPrices}
  alias PhoenixKitEcommerce.APICase
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.StorefrontCache

  setup do
    catalogue = F.shop_catalogue!()
    user = F.user!()
    %{catalogue: catalogue, user: user, ctx: F.ctx(user)}
  end

  defp set_prices(items, ctx),
    do: APICase.call("ecommerce.set_prices", %{"items" => items}, ctx)

  # The handler without the schema in front of it: for the tests that pin the
  # planner's own second line of defence (a malformed price a client's schema
  # would already have refused).
  defp set_prices_raw(items, ctx), do: SetPrices.run(%{"items" => items}, ctx)

  defp ecommerce(item), do: F.reload!(item).data["ecommerce"]

  defp dangerous?(item, price, ctx),
    do:
      SetPrices.dangerous?(
        %{"items" => [%{"ref" => %{"id" => item.uuid}, "price" => price}]},
        ctx
      )

  describe "the write" do
    test "sets price, compare_at and an option price in one call", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue, %{sku: "SP-1"})
      F.attach_set!(item, "Liquid Color", "liquid_color", [{"Black", "black"}, {"Blue", "blue"}])

      row = %{
        "ref" => %{"sku" => "SP-1"},
        "price" => "110.00",
        "compare_at" => "150.00",
        "price_modifiers" => %{"liquid_color" => %{"black" => "32.00"}}
      }

      assert {:ok, %{"results" => [result], "summary" => %{"updated" => 1}}} =
               set_prices([row], ctx)

      assert result["action"] == "updated"
      assert result["id"] == item.uuid
      assert result["changes"]["price"] == %{"from" => "100.00", "to" => "110.00"}
      assert result["ref"] == %{"sku" => "SP-1"}

      reloaded = F.reload!(item)
      assert Decimal.equal?(reloaded.base_price, Decimal.new("110.00"))
      assert reloaded.data["ecommerce"]["compare_at_price"] == "150.00"

      assert reloaded.data["ecommerce"]["price_modifiers"] == %{
               "liquid_color" => %{"black" => "32.00"}
             }
    end

    test "option prices of several products are checked against each product's own sets",
         %{catalogue: catalogue, ctx: ctx} do
      one = F.item!(catalogue)
      two = F.item!(catalogue)
      three = F.item!(catalogue)
      F.attach_set!(one, "Liquid Color", "liquid_color", [{"Black", "black"}])
      F.attach_set!(two, "Size", "size", [{"Large", "large"}])
      F.attach_set!(three, "Finish", "finish", [{"Matte", "matte"}])

      rows = [
        %{
          "ref" => %{"id" => one.uuid},
          "price_modifiers" => %{"liquid_color" => %{"black" => "3.00"}}
        },
        %{"ref" => %{"id" => two.uuid}, "price_modifiers" => %{"size" => %{"large" => "4.00"}}},
        %{
          "ref" => %{"id" => three.uuid},
          "price_modifiers" => %{"liquid_color" => %{"black" => "1.00"}}
        }
      ]

      assert {:ok, %{"results" => [first, second, third]}} = set_prices(rows, ctx)

      assert first["action"] == "updated"
      assert second["action"] == "updated"
      assert third["action"] == "error"

      assert [%{"path" => "price_modifiers.liquid_color", "allowed" => ["finish"]}] =
               third["error"]["context"]["errors"]

      assert ecommerce(one)["price_modifiers"] == %{"liquid_color" => %{"black" => "3.00"}}
      assert ecommerce(two)["price_modifiers"] == %{"size" => %{"large" => "4.00"}}
    end

    test "touches nothing it was not asked to: other shop fields, the Shopify sub-map, translations",
         %{catalogue: catalogue, ctx: ctx} do
      item =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "Mug"},
            "ecommerce" => %{
              "shop_status" => "active",
              "tags" => ["a", "b"],
              "vendor" => "V",
              "shopify" => %{"product_id" => "9001", "handle" => "mug"}
            }
          }
        })

      assert {:ok, _} =
               set_prices([%{"ref" => %{"id" => item.uuid}, "compare_at" => "20.00"}], ctx)

      reloaded = F.reload!(item)
      assert reloaded.data["ecommerce"]["tags"] == ["a", "b"]
      assert reloaded.data["ecommerce"]["vendor"] == "V"
      assert reloaded.data["ecommerce"]["shop_status"] == "active"
      assert reloaded.data["ecommerce"]["shopify"] == %{"product_id" => "9001", "handle" => "mug"}
      assert reloaded.data["en"] == %{"_name" => "Mug"}
      assert reloaded.data["ecommerce"]["compare_at_price"] == "20.00"
    end

    test "null clears compare_at and removes one option price", %{catalogue: catalogue, ctx: ctx} do
      item =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{
              "shop_status" => "active",
              "compare_at_price" => "30.00",
              "price_modifiers" => %{"c" => %{"x" => "1.00", "y" => "2.00"}}
            }
          }
        })

      F.attach_set!(item, "Option C", "c", [{"X", "x"}, {"Y", "y"}])

      row = %{
        "ref" => %{"id" => item.uuid},
        "compare_at" => nil,
        "price_modifiers" => %{"c" => %{"x" => nil}}
      }

      assert {:ok, %{"summary" => %{"updated" => 1}}} = set_prices([row], ctx)

      assert ecommerce(item)["compare_at_price"] == nil
      assert ecommerce(item)["price_modifiers"] == %{"c" => %{"y" => "2.00"}}
    end

    test "an unchanged row writes nothing and logs nothing", %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      before = F.reload!(item)

      assert {:ok, %{"results" => [%{"action" => "unchanged"}], "summary" => %{"unchanged" => 1}}} =
               set_prices([%{"ref" => %{"id" => item.uuid}, "price" => "100.00"}], ctx)

      assert F.reload!(item).updated_at == before.updated_at
      refute_activity_logged("item.updated", resource_uuid: item.uuid)
    end
  end

  describe "rows are independent" do
    test "a missing product, an ambiguous sku, a duplicate and a bad price do not stop the good row",
         %{catalogue: catalogue, ctx: ctx} do
      good = F.item!(catalogue, %{sku: "SP-GOOD"})
      F.item!(catalogue, %{sku: "SP-TWICE"})
      F.item!(catalogue, %{sku: "SP-TWICE"})
      priced = F.item!(catalogue, %{sku: "SP-BADPRICE"})

      rows = [
        %{"ref" => %{"sku" => "SP-MISSING"}, "price" => "5.00"},
        %{"ref" => %{"sku" => "SP-TWICE"}, "price" => "5.00"},
        %{"ref" => %{"sku" => "SP-GOOD"}, "price" => "105.00"},
        %{"ref" => %{"id" => good.uuid}, "price" => "106.00"},
        %{"ref" => %{"sku" => "SP-BADPRICE"}, "price" => "12,5"}
      ]

      # `"12,5"` is refused by the schema in production (the executor's 422, pinned
      # in `tools_test.exs` and `executor_test.exs`); this is the planner's own
      # second line of defence, reached directly.
      assert {:ok, %{"results" => results, "summary" => summary}} = set_prices_raw(rows, ctx)

      assert Enum.map(results, & &1["action"]) == ["error", "error", "updated", "error", "error"]

      assert Enum.map(results, &(&1["error"] && &1["error"]["code"])) ==
               ["not_found", "ambiguous_ref", nil, "duplicate_line", "validation_failed"]

      assert summary == %{"error" => 4, "unchanged" => 0, "updated" => 1}
      assert Decimal.equal?(F.reload!(good).base_price, Decimal.new("105.00"))
      assert Decimal.equal?(F.reload!(priced).base_price, Decimal.new("100.00"))
    end

    test "an unknown option and an unknown value fail their rows with the allowed names",
         %{catalogue: catalogue, ctx: ctx} do
      with_set = F.item!(catalogue)
      F.attach_set!(with_set, "Liquid Color", "liquid_color", [{"Black", "black"}])
      other = F.item!(catalogue)

      rows = [
        %{"ref" => %{"id" => with_set.uuid}, "price_modifiers" => %{"size" => %{"l" => "3.00"}}},
        %{
          "ref" => %{"id" => other.uuid},
          "price_modifiers" => %{"liquid_color" => %{"green" => "3.00"}}
        }
      ]

      assert {:ok, %{"results" => [first, second]}} = set_prices(rows, ctx)

      assert first["error"]["code"] == "validation_failed"

      assert [%{"path" => "price_modifiers.size", "allowed" => ["liquid_color"]}] =
               first["error"]["context"]["errors"]

      # the second item has no option sets at all, so every option is unknown to it
      assert second["error"]["code"] == "validation_failed"

      assert [%{"path" => "price_modifiers.liquid_color", "allowed" => []}] =
               second["error"]["context"]["errors"]
    end
  end

  describe "concurrent writes" do
    test "a plan made before another writer stored a different option price keeps that price",
         %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      F.attach_set!(item, "Liquid Color", "liquid_color", [{"Black", "black"}])
      F.attach_set!(item, "Size", "size", [{"Large", "large"}])
      stale = F.reload!(item)

      # the plan is made from the item as it was ...
      row = %{"price_modifiers" => %{"size" => %{"large" => "4.00"}}}
      assert {:ok, plan} = PricePlan.plan(row, stale, pct: 30, sets: nil)
      assert plan.owned_paths == [["ecommerce", "price_modifiers", "size", "large"]]

      # ... another API call stores a different option before it is written ...
      other = %{"liquid_color" => %{"black" => "3.00"}}

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               set_prices([%{"ref" => %{"id" => item.uuid}, "price_modifiers" => other}], ctx)

      # ... and the stale plan is written afterwards
      paths = plan.owned_paths
      entry = {stale, plan.attrs, data_owned_paths: paths, logged_data_paths: paths}
      opts = [actor_uuid: ctx.actor.user_uuid, mode: "auto"]
      assert [{:ok, _}] = CatalogueWrites.update_rows([entry], opts)

      assert ecommerce(item)["price_modifiers"] == %{
               "liquid_color" => %{"black" => "3.00"},
               "size" => %{"large" => "4.00"}
             }
    end
  end

  describe "the change log" do
    test "names the key's owner, the API, the tool and the key prefix", %{
      catalogue: catalogue,
      user: user,
      ctx: ctx
    } do
      item = F.item!(catalogue)

      assert {:ok, _} = set_prices([%{"ref" => %{"id" => item.uuid}, "price" => "101.00"}], ctx)

      assert_activity_logged("item.updated",
        resource_uuid: item.uuid,
        actor_uuid: user.uuid,
        metadata_has: %{
          "via" => "api",
          "tool" => "ecommerce.set_prices",
          "key_prefix" => "a1b2c3d4",
          "request_id" => "req-test"
        }
      )
    end

    test "an approved call names who approved it", %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      approver = Ecto.UUID.generate()

      assert {:ok, _} =
               set_prices(
                 [%{"ref" => %{"id" => item.uuid}, "price" => "101.00"}],
                 Map.put(ctx, :approved_by_uuid, approver)
               )

      assert_activity_logged("item.updated",
        resource_uuid: item.uuid,
        metadata_has: %{"approved_by_uuid" => approver}
      )
    end
  end

  describe "dry run" do
    test "returns a preview and a fingerprint and writes nothing", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue, %{sku: "SP-DRY"})

      rows = [
        %{"ref" => %{"sku" => "SP-DRY"}, "price" => "150.00"},
        %{"ref" => %{"sku" => "SP-NONE"}, "price" => "1.00"}
      ]

      assert {:preview, preview, fingerprint} = set_prices(rows, %{ctx | dry_run?: true})

      assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      assert preview["totals"]["update"] == 1
      assert preview["totals"]["error"] == 1
      assert preview["totals"]["largest_price_change_pct"] == "50.0"

      assert [
               %{"action" => "update", "changes" => %{"price" => %{"to" => "150.00"}}},
               %{"action" => "error"}
             ] = preview["rows"]

      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("100.00"))
      refute_activity_logged("item.updated", resource_uuid: item.uuid)
    end

    test "the fingerprint moves when a value the call reads changes in between", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      dry = %{ctx | dry_run?: true}
      rows = [%{"ref" => %{"id" => item.uuid}, "price" => "150.00"}]

      assert {:preview, _, before} = set_prices(rows, dry)
      assert {:preview, _, same} = set_prices(rows, dry)
      assert before == same

      assert {:ok, _} = set_prices([%{"ref" => %{"id" => item.uuid}, "price" => "101.00"}], ctx)

      assert {:preview, _, after_change} = set_prices(rows, dry)
      refute before == after_change
    end
  end

  describe "dangerous?/2" do
    test "exactly the threshold is not dangerous, one cent past it is", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)

      refute dangerous?(item, "130.00", ctx)
      assert dangerous?(item, "130.01", ctx)
      refute dangerous?(item, "70.00", ctx)
      assert dangerous?(item, "69.99", ctx)
    end

    test "the threshold is the stored setting, and a garbage setting falls back to 30", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)

      Settings.update_setting_with_module("api_confirm_price_change_pct", "5", "shop")
      assert dangerous?(item, "106.00", ctx)

      Settings.update_setting_with_module("api_confirm_price_change_pct", "lots", "shop")
      refute dangerous?(item, "130.00", ctx)
      assert dangerous?(item, "130.01", ctx)
    end

    test "a first price is never held back", %{catalogue: catalogue, ctx: ctx} do
      for current <- [nil, Decimal.new("0.00")] do
        item = F.item!(catalogue, %{base_price: current})
        refute dangerous?(item, "9999.00", ctx)
      end
    end

    test "the size of the batch is core's rule, not this tool's", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      items = for _ <- 1..3, do: F.item!(catalogue)
      rows = Enum.map(items, &%{"ref" => %{"id" => &1.uuid}, "price" => "101.00"})

      Settings.update_setting_with_module("api_confirm_batch_over", "2", "api")
      refute SetPrices.dangerous?(%{"items" => rows}, ctx)
    end

    test "a refusal is not dangerous: the handler answers it itself", %{ctx: ctx} do
      F.put_config!("shop_product_source", "legacy")

      refute SetPrices.dangerous?(
               %{"items" => [%{"ref" => %{"sku" => "X"}, "price" => "1.00"}]},
               ctx
             )
    end
  end

  describe "warnings" do
    test "the Shopify warning only for a linked product, only while the sync is on", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      shopify = PhoenixKitEcommerce.shopify_enabled?()

      on_exit(fn ->
        Settings.update_boolean_setting_with_module("shop_shopify_enabled", shopify, "shop")
      end)

      linked =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{"shop_status" => "active", "shopify" => %{"product_id" => "7"}}
          }
        })

      plain = F.item!(catalogue)

      Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")

      assert {:ok, %{"results" => [a, b]}} =
               set_prices(
                 [
                   %{"ref" => %{"id" => linked.uuid}, "price" => "101.00"},
                   %{"ref" => %{"id" => plain.uuid}, "price" => "101.00"}
                 ],
                 ctx
               )

      assert a["warnings"] == ["shopify_sync_may_overwrite"]
      assert b["warnings"] == []

      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")

      assert {:ok, %{"results" => [c]}} =
               set_prices([%{"ref" => %{"id" => linked.uuid}, "price" => "102.00"}], ctx)

      assert c["warnings"] == []
    end
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
      item = F.item!(catalogue)
      row = %{"ref" => %{"id" => item.uuid}, "price" => "101.00"}

      :stale = StorefrontCache.fetch(:probe, fn -> :stale end)

      assert {:preview, _preview, _fingerprint} = set_prices([row], %{ctx | dry_run?: true})
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale

      assert {:ok, %{"summary" => %{"updated" => 1}}} = set_prices([row], ctx)
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh

      StorefrontCache.clear()
      :stale = StorefrontCache.fetch(:probe, fn -> :stale end)
      assert {:ok, %{"summary" => %{"unchanged" => 1}}} = set_prices([row], ctx)
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale
    end
  end

  test "the legacy source is refused and nothing is written", %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)
    F.put_config!("shop_product_source", "legacy")

    assert {:error, :unsupported_source, _detail, %{reason: "legacy_source"}} =
             set_prices([%{"ref" => %{"id" => item.uuid}, "price" => "5.00"}], ctx)

    assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("100.00"))
  end
end
