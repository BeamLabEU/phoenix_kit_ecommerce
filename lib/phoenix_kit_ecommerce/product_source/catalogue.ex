defmodule PhoenixKitEcommerce.ProductSource.Catalogue do
  @moduledoc """
  `ProductSource` adapter reading `phoenix_kit_catalogue` items/categories
  and returning hand-built `%Product{}`/`%Category{}` view-structs (see
  `PhoenixKitEcommerce.ProductSource.Catalogue.View`) so the facade,
  `Options`, `PriceDisplay`, `CartItem` and the storefront never need to
  know which adapter is active.

  Every callback here is read-only: `Query` never writes, and every
  view-struct comes back `__meta__: :built` — `Repo.update/preload/delete`
  on one is a bug (`update_product/2`/`delete_product/2` already refuse
  it). `ProductSource.current/0` only ever returns this module when
  `phoenix_kit_catalogue` is loaded, so the direct calls into it below
  are safe at runtime; `@compile {:no_warn_undefined, ...}` only
  quietens the compiler's static xref check for hosts that don't
  declare the optional dependency.
  """

  @behaviour PhoenixKitEcommerce.ProductSource

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View
  alias PhoenixKitEcommerce.Translations

  # ============================================================
  # PRODUCTS
  # ============================================================

  @impl PhoenixKitEcommerce.ProductSource
  def list_products(opts \\ []) do
    opts |> Query.list_items() |> build_products(opts)
  end

  @impl PhoenixKitEcommerce.ProductSource
  def list_products_with_count(opts \\ []) do
    {items, total} = Query.list_items_with_count(opts)
    {build_products(items, opts), total}
  end

  @impl PhoenixKitEcommerce.ProductSource
  def list_products_by_ids(ids) do
    ids |> Query.list_items_by_uuids() |> build_products([])
  end

  @impl PhoenixKitEcommerce.ProductSource
  def get_product(id, opts \\ [])

  def get_product(id, opts) when is_binary(id) do
    case Query.get_item(id) do
      nil -> nil
      item -> build_product(item, opts)
    end
  end

  def get_product(_, _opts), do: nil

  @impl PhoenixKitEcommerce.ProductSource
  def get_product_by_slug_localized(slug, language, opts \\ []) do
    with {:ok, item} <-
           fetch_scoped(Catalogue.get_item_by_slug(slug, language, catalogue_opts(opts))) do
      {:ok, build_product(item, opts)}
    end
  end

  @impl PhoenixKitEcommerce.ProductSource
  def get_product_by_any_slug(slug, opts \\ []) do
    lang = Translations.default_language()
    catalogue_opts = catalogue_opts(opts) |> Keyword.put(:any_lang, true)

    case fetch_scoped(Catalogue.get_item_by_slug(slug, lang, catalogue_opts)) do
      {:ok, item, matched_lang} -> {:ok, build_product(item, opts), matched_lang}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # ============================================================
  # CATEGORIES
  # ============================================================

  @impl PhoenixKitEcommerce.ProductSource
  def list_categories(opts \\ []) do
    opts |> Query.list_categories() |> Enum.map(&build_category(&1, opts))
  end

  @impl PhoenixKitEcommerce.ProductSource
  def get_category(id, opts \\ [])

  def get_category(id, opts) when is_binary(id) do
    case Query.get_category(id) do
      nil -> nil
      category -> build_category(category, opts)
    end
  end

  def get_category(_, _opts), do: nil

  @impl PhoenixKitEcommerce.ProductSource
  def get_category_by_slug_localized(slug, language, opts \\ []) do
    with {:ok, category} <-
           fetch_scoped(Catalogue.get_category_by_slug(slug, language, catalogue_opts(opts))) do
      {:ok, build_category(category, opts)}
    end
  end

  @impl PhoenixKitEcommerce.ProductSource
  def get_category_by_any_slug(slug, opts \\ []) do
    lang = Translations.default_language()
    catalogue_opts = catalogue_opts(opts) |> Keyword.put(:any_lang, true)

    case fetch_scoped(Catalogue.get_category_by_slug(slug, lang, catalogue_opts)) do
      {:ok, category, matched_lang} -> {:ok, build_category(category, opts), matched_lang}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl PhoenixKitEcommerce.ProductSource
  def product_counts_by_category do
    Query.product_counts_by_category()
  end

  # ============================================================
  # FILTER AGGREGATION
  # ============================================================

  @impl PhoenixKitEcommerce.ProductSource
  def aggregate_filter_values(opts \\ []) do
    filters = PhoenixKitEcommerce.get_enabled_storefront_filters()
    category_uuid = Keyword.get(opts, :category_uuid)

    Enum.reduce(filters, %{}, fn filter, acc ->
      Map.put(acc, filter["key"], aggregate_single_filter(filter, category_uuid))
    end)
  end

  @impl PhoenixKitEcommerce.ProductSource
  def get_price_range_for(opts \\ []) do
    Query.price_range(opts)
  end

  defp aggregate_single_filter(%{"type" => "price_range"}, category_uuid) do
    {min_price, max_price} = get_price_range_for(category_uuid: category_uuid)
    %{min: min_price, max: max_price}
  end

  defp aggregate_single_filter(%{"type" => "vendor"}, category_uuid) do
    Query.vendor_counts(category_uuid: category_uuid)
  end

  # `attribute_set` facets, backed by `Query.attribute_set_counts/2`.
  # `metadata_option` (`option_key`) is an alias of `attribute_set`
  # (`set_slug`) so a filter config saved before this block — the live
  # "size" filter — keeps working unchanged (2026-09-06 design doc §5
  # "Блок 5").
  defp aggregate_single_filter(%{"type" => "attribute_set"} = filter, category_uuid) do
    case filter["set_slug"] || filter["key"] do
      slug when is_binary(slug) -> Query.attribute_set_counts(slug, category_uuid: category_uuid)
      _ -> []
    end
  end

  defp aggregate_single_filter(%{"type" => "metadata_option"} = filter, category_uuid) do
    case filter["option_key"] || filter["key"] do
      slug when is_binary(slug) -> Query.attribute_set_counts(slug, category_uuid: category_uuid)
      _ -> []
    end
  end

  defp aggregate_single_filter(_filter, _category_uuid), do: []

  # ============================================================
  # Helpers
  # ============================================================

  defp build_products(items, opts) do
    sets_by_item = resolve_sets(items)
    categories_by_uuid = maybe_categories_by_uuid(items, opts)

    Enum.map(items, fn item ->
      View.product_view(item,
        sets: Map.get(sets_by_item, item.uuid, []),
        category: category_for(item, categories_by_uuid)
      )
    end)
  end

  defp build_product(item, opts) do
    sets = AttributeSets.resolve_for_item(item.uuid)
    category = single_category(item, opts)
    View.product_view(item, sets: sets, category: category)
  end

  defp resolve_sets([]), do: %{}

  defp resolve_sets(items) do
    items |> Enum.map(& &1.uuid) |> AttributeSets.resolve_for_items()
  end

  defp maybe_categories_by_uuid(items, opts) do
    if preload_category?(opts) do
      items
      |> Enum.map(& &1.category_uuid)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Query.list_categories_by_uuids()
      |> Map.new(&{&1.uuid, View.category_view(&1)})
    end
  end

  defp single_category(%{category_uuid: nil}, _opts), do: nil

  defp single_category(item, opts) do
    if preload_category?(opts) do
      case Query.get_category(item.category_uuid) do
        nil -> nil
        category -> View.category_view(category)
      end
    end
  end

  defp preload_category?(opts) do
    :category in List.wrap(Keyword.get(opts, :preload))
  end

  # `build_category/2` is the category counterpart of `build_product/2` +
  # `single_category/2`: `View.category_view/2` never leaves the
  # `:parent` field as the struct's own `Ecto.Association.NotLoaded`
  # default (a view-struct can never actually be `Repo.preload/2`'d), so
  # every category-returning callback routes through here instead of
  # calling `View.category_view/1` directly.
  defp build_category(category, opts) do
    View.category_view(category, parent: resolve_parent(category, opts))
  end

  defp resolve_parent(%{parent_uuid: nil}, _opts), do: nil

  defp resolve_parent(category, opts) do
    if preload_parent?(opts) do
      case Query.get_category(category.parent_uuid) do
        nil -> nil
        parent -> View.category_view(parent)
      end
    end
  end

  defp preload_parent?(opts) do
    :parent in List.wrap(Keyword.get(opts, :preload))
  end

  # `:preload` here names an ecommerce VIEW-STRUCT association
  # (`single_category/2`'s `:category` — see `preload_category?/1`), not
  # a real catalogue Ecto association: `PhoenixKitCatalogue.Schemas.Item`/
  # `Category` happen to have real `:category`/`:parent` associations of
  # their own, so forwarding it verbatim would trigger a wasted (if
  # harmless, for those two names) extra `Repo.preload` inside catalogue,
  # and a genuinely ecommerce-only preload name would raise there. Never
  # forward it.
  defp catalogue_opts(opts), do: Keyword.delete(opts, :preload)

  defp category_for(_item, nil), do: nil
  defp category_for(item, categories_by_uuid), do: Map.get(categories_by_uuid, item.category_uuid)

  # A slug lookup is global to `phoenix_kit_cat_items`/`_categories` — the
  # shop reads only the one configured catalogue (`Query.catalogue_uuid/0`),
  # so a hit belonging to a different catalogue (equipment, stock — the
  # owner's other catalogues per the design doc) must miss here exactly
  # like a truly unknown slug.
  defp fetch_scoped({:ok, %{catalogue_uuid: catalogue_uuid}} = result) do
    if catalogue_uuid == Query.catalogue_uuid(), do: result, else: {:error, :not_found}
  end

  defp fetch_scoped({:ok, %{catalogue_uuid: catalogue_uuid}, _lang} = result) do
    if catalogue_uuid == Query.catalogue_uuid(), do: result, else: {:error, :not_found}
  end

  defp fetch_scoped({:error, :not_found} = error), do: error
end
