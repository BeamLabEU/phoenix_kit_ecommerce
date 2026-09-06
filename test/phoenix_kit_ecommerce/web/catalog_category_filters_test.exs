defmodule PhoenixKitEcommerce.Web.CatalogCategoryFiltersTest do
  @moduledoc """
  Per-category `storefront_filters` overrides on the public category page
  (2026-09-06 plan, Task 2): a filter key configured only on the category
  (absent from the global storefront filter config) still renders in the
  sidebar.

  Needs `phoenix_kit_catalogue` loaded — excluded via `test_helper.exs`
  whenever the optional dependency isn't present, same as every other
  `:catalogue` test. `async: false`: flips the process-wide
  `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Gadgets",
        catalogue_uuid: catalogue.uuid,
        slug: %{"en-US" => "gadgets"},
        data: %{
          "ecommerce" => %{
            "storefront_filters" => %{
              "brand" => %{
                "type" => "vendor",
                "label" => "Brand Spotlight",
                "enabled" => true,
                "position" => 5
              }
            }
          }
        }
      })

    %{catalogue: catalogue, category: category, path: "/shop/category/gadgets"}
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

  test "a category-only filter key (absent from the global config) renders in the sidebar",
       %{conn: conn, path: path} do
    {:ok, _view, html} = live(conn, path)

    assert html =~ "Brand Spotlight"
  end
end
