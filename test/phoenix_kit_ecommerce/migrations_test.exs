defmodule PhoenixKitEcommerce.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Migrations

  @tables ~w(
    phoenix_kit_shop_config
    phoenix_kit_shop_shipping_methods
    phoenix_kit_shop_categories
    phoenix_kit_shop_products
    phoenix_kit_shop_product_slugs
    phoenix_kit_shop_category_slugs
    phoenix_kit_shop_carts
    phoenix_kit_shop_cart_items
    phoenix_kit_shop_import_configs
    phoenix_kit_shop_import_logs
  )

  test "chain is V1 and marks phoenix_kit_shop_config" do
    assert Migrations.current_version() == 1
    assert Migrations.version_table() == "phoenix_kit_shop_config"
  end

  test "up_statements creates every owned table idempotently and stamps the marker" do
    stmts = Migrations.up_statements("public")

    for t <- @tables do
      assert Enum.any?(stmts, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{t} ("))
    end

    assert List.last(stmts) == "COMMENT ON TABLE public.phoenix_kit_shop_config IS 'pke_schema:1'"
  end

  test "no statement can destroy data, in either direction" do
    all = Migrations.up_statements("public") ++ Migrations.down_statements("public", 0)

    # The two adopted slug-projection functions (sync_shop_product_slugs/
    # sync_shop_category_slugs) contain a scoped `DELETE FROM ... WHERE
    # <fk>_uuid = NEW.uuid` as their own pre-existing, core-authored
    # upsert-by-replace body (unchanged here) — that is runtime trigger
    # logic being adopted verbatim, not a migration-time destructive
    # statement against the chain's tables, so function bodies are exempt
    # from this scan.
    #
    # The destructive-statement scan targets DELETE as a *statement*
    # (`DELETE FROM ...`), not the referential-action keyword `ON DELETE
    # CASCADE|SET NULL|...` that every adopted foreign key carries
    # verbatim from core's dump — those never delete a row on their own.
    for s <- all, not (s =~ ~r/CREATE OR REPLACE FUNCTION/) do
      refute s =~ ~r/\b(DROP|TRUNCATE)\b/i, "destructive statement: #{s}"
      refute s =~ ~r/\bDELETE\s+FROM\b/i, "destructive statement: #{s}"
      refute s =~ ~r/ALTER TABLE .* DROP/i, "destructive statement: #{s}"
    end
  end

  test "every CREATE INDEX and constraint is guarded" do
    for s <- Migrations.up_statements("public"), s =~ ~r/CREATE (UNIQUE )?INDEX/ do
      assert s =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/
    end

    for s <- Migrations.up_statements("public"), s =~ ~r/ADD CONSTRAINT/ do
      assert s =~ ~r/DO \$\$/ and s =~ ~r/IF NOT EXISTS/
    end
  end

  test "down only rewrites the marker" do
    assert Migrations.down_statements("public", 0) ==
             ["COMMENT ON TABLE public.phoenix_kit_shop_config IS NULL"]

    assert Migrations.down_statements("public", 1) ==
             ["COMMENT ON TABLE public.phoenix_kit_shop_config IS 'pke_schema:1'"]
  end

  test "prefix is validated before it reaches DDL" do
    assert_raise ArgumentError, fn -> Migrations.up_statements("public; DROP") end
  end

  test "the module registers the chain" do
    assert PhoenixKitEcommerce.migration_module() == Migrations
  end

  test "the slug projections come with their functions and triggers, guarded" do
    joined = Enum.join(Migrations.up_statements("public"), "\n")

    for f <- ~w(sync_shop_product_slugs sync_shop_category_slugs) do
      assert joined =~ "CREATE OR REPLACE FUNCTION public.#{f}()"
    end

    for t <- ~w(trg_shop_product_slugs trg_shop_category_slugs) do
      assert joined =~ ~r/IF NOT EXISTS \(SELECT 1 FROM pg_trigger WHERE tgname = '#{t}'/
    end
  end
end
