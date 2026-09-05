defmodule PhoenixKitEcommerce.Catalogue.Extension do
  @moduledoc """
  Structurally implements `PhoenixKitCatalogue.Extension` — the catalogue
  item/category form "extension slot" (spec §2 principle 8). `phoenix_kit_catalogue`
  is an optional dependency, so this module does NOT declare `@behaviour
  PhoenixKitCatalogue.Extension`; that would force it to be loaded at
  compile time. Discovery is duck-typed, the same pattern as
  `PhoenixKitEcommerce.AITranslatable` / `ai_translatables/0`: catalogue
  finds this module via `PhoenixKitEcommerce.catalogue_extensions/0` and is
  responsible for checking it is actually usable before calling it.
  """

  alias PhoenixKitEcommerce.Catalogue.CategoryCommerce
  alias PhoenixKitEcommerce.Catalogue.ItemCommerce
  alias PhoenixKitEcommerce.Catalogue.ShopSections

  @doc "Namespace under `data` this extension owns."
  def key, do: "ecommerce"

  @doc "Whether the Shop section should be shown / absorbed."
  def enabled?, do: PhoenixKitEcommerce.enabled?()

  @doc "Renders the Shop section inside the catalogue item form."
  def item_section(assigns), do: ShopSections.item(assigns)

  @doc "Renders the Shop section inside the catalogue category form."
  def category_section(assigns), do: ShopSections.category(assigns)

  @doc "Validates and shapes `item[\"ecommerce\"]` — see `ItemCommerce.cast/2`."
  def cast_item(params, current), do: ItemCommerce.cast(params, current)

  @doc "Validates and shapes `category[\"ecommerce\"]` — see `CategoryCommerce.cast/2`."
  def cast_category(params, current), do: CategoryCommerce.cast(params, current)
end
