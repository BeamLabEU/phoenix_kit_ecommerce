defmodule PhoenixKitEcommerce.MigrationsShipmentsTest do
  @moduledoc """
  V7 of the module chain: the shipments table. Statement-level checks; the
  table is built for real by `MigrationsUpVersionTest` and exercised by
  `ShipmentsTest`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.{Migrations, Shipment}

  test "shipments_statements creates the table with its keys inline, then four guarded indexes" do
    assert [table | indexes] = Migrations.shipments_statements("public")

    assert table =~ "CREATE TABLE IF NOT EXISTS public.phoenix_kit_shop_shipments ("
    assert table =~ ~s|"uuid" uuid DEFAULT public.uuid_generate_v7() NOT NULL|
    assert table =~ ~s|"order_uuid" uuid NOT NULL|
    assert table =~ ~s|"status" character varying(32) NOT NULL|
    assert table =~ ~s|"context_snapshot" jsonb DEFAULT '{}'::jsonb NOT NULL|
    assert table =~ ~s|"events" jsonb DEFAULT '[]'::jsonb NOT NULL|
    assert table =~ ~s|"submitted_at" timestamp with time zone,|
    assert table =~ ~s|REFERENCES public.phoenix_kit_orders("uuid") ON DELETE CASCADE|

    assert table =~
             ~s|REFERENCES public.phoenix_kit_shop_shipping_methods("uuid") ON DELETE SET NULL|

    assert length(indexes) == 4
    assert Enum.all?(indexes, &(&1 =~ ~r/^CREATE (UNIQUE )?INDEX IF NOT EXISTS /))

    assert [live] = Enum.filter(indexes, &(&1 =~ "UNIQUE"))
    assert live =~ "idx_shop_shipments_live_order ON public.phoenix_kit_shop_shipments"

    for status <- Shipment.live_statuses(), do: assert(live =~ "'#{status}'")

    for status <- Shipment.statuses() -- Shipment.live_statuses(),
        do: refute(live =~ "'#{status}'")
  end

  test "V7 runs last, right before the marker" do
    stmts = Migrations.up_statements("public")
    v7 = Migrations.shipments_statements("public")

    assert Enum.take(stmts, -(length(v7) + 1)) ==
             v7 ++ ["COMMENT ON TABLE public.phoenix_kit_shop_config IS 'pke_schema:7'"]

    refute Enum.any?(Migrations.up_statements("public", 6), &(&1 =~ "phoenix_kit_shop_shipments"))
  end

  test "no V7 statement leaks the public schema under a foreign prefix" do
    stmts = Migrations.shipments_statements("tenant_x")

    refute Enum.any?(stmts, &String.contains?(&1, "public."))
    assert Enum.any?(stmts, &String.contains?(&1, "tenant_x.phoenix_kit_shop_shipments"))
  end

  # Fixed once released, like every version of the chain (V7 is not released
  # yet: `submitted_at` was added to it in review).
  test "the SQL of V7 is pinned, in the public schema and under a prefix" do
    digest = fn statements ->
      statements
      |> Enum.join("\n;;\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    assert digest.(Migrations.shipments_statements("public")) ==
             "28a1b70cc82e4669e907d1772741e09a719d15be9dca78665b501c6383630bac"

    assert digest.(Migrations.shipments_statements("tenant_x")) ==
             "9c728389ac90da02e8f9dbd62e109d9783347221df907ca8ae669f9fb95f09f1"
  end

  test "the prefix is validated before it reaches DDL" do
    assert_raise ArgumentError, fn -> Migrations.shipments_statements("public; DROP") end
  end

  test "down keeps the shipments table, like every table of the chain" do
    down = Migrations.down_statements("public", 6)
    refute Enum.any?(down, &(&1 =~ "shipments"))
    assert down == ["COMMENT ON TABLE public.phoenix_kit_shop_config IS 'pke_schema:6'"]
  end
end
