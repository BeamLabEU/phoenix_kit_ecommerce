defmodule PhoenixKitEcommerce.ProductSource do
  @moduledoc """
  Behaviour for the storefront's product/category read path.

  Two adapters implement it: `PhoenixKitEcommerce.ProductSource.Legacy`
  (today's `phoenix_kit_shop_products`/`phoenix_kit_shop_categories`
  tables, unchanged) and, once `phoenix_kit_catalogue` is present,
  `PhoenixKitEcommerce.ProductSource.Catalogue` (reads catalogue items
  and returns hand-built `%Product{}`/`%Category{}` view-structs so the
  facade, guards, `CartItem`, `Options` and `SeoHelpers` need no changes).

  `current/0` picks the adapter at runtime; `PhoenixKitEcommerce`'s
  public read functions delegate to it so callers never choose an
  adapter themselves.
  """

  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product

  @callback list_products(keyword()) :: [Product.t()]
  @callback list_products_with_count(keyword()) :: {[Product.t()], non_neg_integer()}
  @callback list_products_by_ids([String.t()]) :: [Product.t()]
  @callback get_product(String.t(), keyword()) :: Product.t() | nil
  @callback get_product_by_slug_localized(String.t(), String.t(), keyword()) ::
              {:ok, Product.t()} | {:error, :not_found}
  @callback get_product_by_any_slug(String.t(), keyword()) ::
              {:ok, Product.t(), String.t()} | {:error, :not_found}
  @callback list_categories(keyword()) :: [Category.t()]
  @callback get_category(String.t(), keyword()) :: Category.t() | nil
  @callback get_category_by_slug_localized(String.t(), String.t(), keyword()) ::
              {:ok, Category.t()} | {:error, :not_found}
  @callback get_category_by_any_slug(String.t(), keyword()) ::
              {:ok, Category.t(), String.t()} | {:error, :not_found}
  @callback product_counts_by_category() :: %{String.t() => non_neg_integer()}
  @callback aggregate_filter_values(keyword()) :: map()
  @callback get_price_range_for(keyword()) :: {Decimal.t() | nil, Decimal.t() | nil}

  @legacy_module PhoenixKitEcommerce.ProductSource.Legacy
  @catalogue_module PhoenixKitEcommerce.ProductSource.Catalogue

  @doc """
  Returns the adapter module for the currently active product source.

  `Catalogue` only when `phoenix_kit_catalogue` is loaded AND the
  `shop_product_source` config key (`phoenix_kit_shop_config`) is
  `"catalogue"`; `Legacy` otherwise — including when the key is absent
  or the catalogue module isn't loaded, so a host without the optional
  `phoenix_kit_catalogue` dependency always gets `Legacy` regardless of
  the stored key.

  Reads the config on every call rather than caching it here:
  `PhoenixKitEcommerce.get_config/1` is a plain primary-key
  `repo().get/2` against `phoenix_kit_shop_config` (no ETS/settings-cache
  layer sits in front of it — the key lives in the shop config table,
  not in `PhoenixKit.Settings`, and every writer, the test suite
  included, updates that row directly), so this is one point read per
  facade call. Accepted so that the switch takes effect without a
  restart: a per-process memo would go stale in a long-lived LiveView
  process, and a node-wide cache has no invalidation hook because the
  row is written without going through this module. The `Code.
  ensure_loaded?/1` guard runs FIRST so a host without the optional
  `phoenix_kit_catalogue` dependency never pays for the read at all.
  """
  def current do
    if Code.ensure_loaded?(PhoenixKitCatalogue) and
         PhoenixKitEcommerce.get_config("shop_product_source") == "catalogue" do
      @catalogue_module
    else
      @legacy_module
    end
  end

  # Max length for a user-supplied search term. Anything longer is
  # truncated: ILIKE against unindexed JSONB expansions is linear in both
  # pattern and row count, so an unbounded public `?search=` param would be
  # a cheap seq-scan amplifier.
  @max_search_term_length 100

  @doc false
  # Builds a safe `%term%` ILIKE pattern from raw user input: caps the
  # length, strips NUL bytes (Postgres rejects them in text params), and
  # escapes LIKE metacharacters so `%`, `_`, and `\` match literally —
  # a search for "100%" must not match every "100", and SKUs routinely
  # contain underscores. Shared by both adapters so the two can never
  # drift on what a search term is allowed to mean.
  @spec search_like_pattern(String.t()) :: String.t()
  def search_like_pattern(search) when is_binary(search) do
    escaped =
      search
      |> String.replace(<<0>>, "")
      |> String.slice(0, @max_search_term_length)
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%#{escaped}%"
  end
end
