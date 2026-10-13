defmodule PhoenixKitEcommerce.API.Loader do
  @moduledoc """
  Loads products for the public API from whichever product source is active
  and wraps each in an `PhoenixKitEcommerce.API.Record`: the storefront
  view-struct, its category chain, the visibility facts and the resulting
  state. One code path serves the search indexer (Task 5) and every public
  tool, for both sources.

  On the Catalogue source the raw item is read too, because the view-struct
  collapses the catalogue's `inactive`, `discontinued` and `deleted` states
  into `"archived"` and the visibility rule (spec 7.1) tells them apart.
  """

  import Ecto.Query, warn: false

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Schemas.Item}
  @compile {:no_warn_undefined, PhoenixKitEcommerce.ProductSource.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitEcommerce.ProductSource.Catalogue.Query}

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item, as: CatItem
  alias PhoenixKitEcommerce.API.Facts
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.API.Visibility
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query, as: CatalogueQuery
  alias PhoenixKitEcommerce.ProductSource.Legacy

  @max_chain_depth 20

  @doc """
  Records for `ids`, keyed by product id. Unknown, malformed and
  out-of-catalogue ids are absent from the map.

  Options: `:language` (the language option labels are written in; Catalogue
  source only) and `:categories` (a map from `categories/0`, so a caller that
  loads many chunks reads the category table once).
  """
  @spec load([term()], keyword()) :: %{String.t() => Record.t()}
  def load(ids, opts \\ []) when is_list(ids) do
    ids = ids |> Enum.filter(&valid_uuid?/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      categories = Keyword.get_lazy(opts, :categories, &categories/0)

      case ProductSource.current() do
        ProductSource.Catalogue -> load_catalogue(ids, categories, opts)
        _legacy -> load_legacy(ids, categories)
      end
    end
  end

  @doc "Every category of the active source by uuid; hidden and deleted ones included."
  @spec categories() :: %{String.t() => PhoenixKitEcommerce.Category.t()}
  def categories do
    ProductSource.current().list_categories([]) |> Map.new(&{&1.uuid, &1})
  end

  @doc """
  The ids of every product the source holds, listed or not (the rebuild decides
  which are listed). `{:error, :no_catalogue}` when the Catalogue source is on
  but the shop's catalogue cannot be resolved: a caller must then change nothing
  rather than treat the shop as empty.
  """
  @spec all_ids() :: {:ok, [String.t()]} | {:error, :no_catalogue}
  def all_ids do
    case ProductSource.current() do
      ProductSource.Catalogue ->
        case CatalogueQuery.catalogue_uuid() do
          nil ->
            {:error, :no_catalogue}

          uuid ->
            {:ok,
             RepoHelper.repo().all(
               from(i in CatItem, where: i.catalogue_uuid == ^uuid, select: i.uuid)
             )}
        end

      _legacy ->
        {:ok, RepoHelper.repo().all(from(p in Product, select: p.uuid))}
    end
  end

  @doc "The uuid of the shop's one catalogue; `nil` on the Legacy source or when it cannot be resolved."
  @spec shop_catalogue_uuid() :: String.t() | nil
  def shop_catalogue_uuid do
    case ProductSource.current() do
      ProductSource.Catalogue -> CatalogueQuery.catalogue_uuid()
      _legacy -> nil
    end
  end

  @doc """
  False only when the Catalogue source is on and the shop's catalogue cannot be
  resolved (renamed, deleted). A writer must then change nothing: an empty answer
  is "I cannot tell", not "the shop is empty". Always true on the Legacy source.
  """
  @spec source_resolvable?() :: boolean()
  def source_resolvable? do
    ProductSource.current() != ProductSource.Catalogue or CatalogueQuery.catalogue_uuid() != nil
  end

  @doc "True when the shop's catalogue exists and its status is `active`."
  @spec catalogue_listed?() :: boolean()
  def catalogue_listed? do
    with uuid when is_binary(uuid) <- CatalogueQuery.catalogue_uuid(),
         %{status: status} <- Catalogue.get_catalogue(uuid) do
      status == "active"
    else
      _other -> false
    end
  end

  @doc "The ids of the products that sit directly in any of `category_uuids`."
  @spec item_ids_in_categories([String.t()]) :: [String.t()]
  def item_ids_in_categories(category_uuids) when is_list(category_uuids) do
    case Enum.filter(category_uuids, &valid_uuid?/1) do
      [] -> []
      uuids -> products_in_categories(uuids)
    end
  end

  defp products_in_categories(uuids) do
    case ProductSource.current() do
      ProductSource.Catalogue ->
        case CatalogueQuery.catalogue_uuid() do
          nil ->
            []

          catalogue ->
            RepoHelper.repo().all(
              from(i in CatItem,
                where: i.catalogue_uuid == ^catalogue and i.category_uuid in ^uuids,
                select: i.uuid
              )
            )
        end

      _legacy ->
        RepoHelper.repo().all(
          from(p in Product, where: p.category_uuid in ^uuids, select: p.uuid)
        )
    end
  end

  @doc "The category and its ancestors, root first. Stops at a cycle or after #{@max_chain_depth} levels."
  @spec chain(map() | nil, %{String.t() => map()}) :: [map()]
  def chain(nil, _categories), do: []
  def chain(category, categories), do: build_chain(category, categories, [], 0)

  defp build_chain(nil, _categories, acc, _depth), do: acc
  defp build_chain(_category, _categories, acc, depth) when depth >= @max_chain_depth, do: acc

  defp build_chain(category, categories, acc, depth) do
    parent = category.parent_uuid && Map.get(categories, category.parent_uuid)
    build_chain(parent, categories, [category | acc], depth + 1)
  end

  @doc "`root` and the uuids of every descendant, each once (a cycle cannot repeat a uuid)."
  @spec subtree_uuids(String.t(), %{String.t() => map()}) :: [String.t()]
  def subtree_uuids(root, categories) do
    children = categories |> Map.values() |> Enum.group_by(& &1.parent_uuid, & &1.uuid)
    walk([root], children, MapSet.new([root]))
  end

  defp walk([], _children, seen), do: MapSet.to_list(seen)

  defp walk([uuid | rest], children, seen) do
    new = children |> Map.get(uuid, []) |> Enum.reject(&MapSet.member?(seen, &1))
    walk(rest ++ new, children, Enum.reduce(new, seen, &MapSet.put(&2, &1)))
  end

  # --- the two sources -------------------------------------------------------

  defp load_catalogue(ids, categories, opts) do
    items = CatalogueQuery.list_items_by_uuids(ids)
    products = CatalogueSource.products_for_items(items, Keyword.take(opts, [:language]))
    listed? = catalogue_listed?()

    items
    |> Enum.zip(products)
    |> Map.new(fn {item, product} ->
      category = Map.get(categories, item.category_uuid)

      facts = %Facts{
        item_status: item.status,
        shop_status: product.merchant_status || product.status,
        category_status: category && category.status,
        catalogue_listed?: listed?,
        position: item.position || 0
      }

      {item.uuid, record(item.uuid, product, category, categories, facts)}
    end)
  end

  defp load_legacy(ids, categories) do
    ids
    |> Legacy.list_products_by_ids()
    |> Map.new(fn product ->
      category = Map.get(categories, product.category_uuid)

      facts = %Facts{
        item_status: "active",
        shop_status: product.status,
        category_status: category && category.status,
        catalogue_listed?: true,
        position: 0
      }

      {product.uuid, record(product.uuid, product, category, categories, facts)}
    end)
  end

  defp record(id, product, category, categories, facts) do
    %Record{
      id: id,
      product: product,
      category: category,
      chain: chain(category, categories),
      facts: facts,
      state: Visibility.classify(facts)
    }
  end

  defp valid_uuid?(value), do: is_binary(value) and UUIDUtils.valid?(value)
end
