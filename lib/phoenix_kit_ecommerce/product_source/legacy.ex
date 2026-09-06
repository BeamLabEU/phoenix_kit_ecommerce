defmodule PhoenixKitEcommerce.ProductSource.Legacy do
  @moduledoc """
  `ProductSource` adapter over `phoenix_kit_shop_products` and
  `phoenix_kit_shop_categories`.

  This is today's product/category query code, moved here verbatim from
  `PhoenixKitEcommerce` — no behavior change. It is (and stays) the
  default adapter: `ProductSource.current/0` picks it whenever the
  catalogue source isn't explicitly switched on.
  """

  @behaviour PhoenixKitEcommerce.ProductSource

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.SlugResolver
  alias PhoenixKitEcommerce.Translations

  # ============================================
  # PRODUCTS
  # ============================================

  @impl PhoenixKitEcommerce.ProductSource
  def list_products(opts \\ []) do
    Product
    |> apply_product_filters(opts)
    |> order_by([p], desc: p.inserted_at)
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().all()
  end

  @impl PhoenixKitEcommerce.ProductSource
  def list_products_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page

    base_query =
      Product
      |> apply_product_filters(opts)

    total = repo().aggregate(base_query, :count)

    products =
      base_query
      |> order_by([p], desc: p.inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> maybe_preload(Keyword.get(opts, :preload, [:category]))
      |> repo().all()

    {products, total}
  end

  @impl PhoenixKitEcommerce.ProductSource
  def list_products_by_ids([]), do: []

  def list_products_by_ids(ids) when is_list(ids) do
    Product |> where([p], p.uuid in ^ids) |> repo().all()
  end

  @impl PhoenixKitEcommerce.ProductSource
  def get_product(id, opts \\ [])

  def get_product(id, opts) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      Product
      |> where([p], p.uuid == ^id)
      |> maybe_preload(Keyword.get(opts, :preload))
      |> repo().one()
    else
      nil
    end
  end

  def get_product(_, _opts), do: nil

  @impl PhoenixKitEcommerce.ProductSource
  def get_product_by_slug_localized(slug, language, opts \\ []) do
    SlugResolver.find_product_by_slug(slug, language, opts)
  end

  @impl PhoenixKitEcommerce.ProductSource
  def get_product_by_any_slug(slug, opts \\ []) do
    SlugResolver.find_product_by_any_slug(slug, opts)
  end

  # ============================================
  # CATEGORIES
  # ============================================

  @impl PhoenixKitEcommerce.ProductSource
  def list_categories(opts \\ []) do
    Category
    |> apply_category_filters(opts)
    |> order_by([c], [c.position, c.name])
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().all()
  end

  @impl PhoenixKitEcommerce.ProductSource
  def get_category(id, opts \\ [])

  def get_category(id, opts) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      Category
      |> where([c], c.uuid == ^id)
      |> maybe_preload(Keyword.get(opts, :preload))
      |> repo().one()
    else
      nil
    end
  end

  def get_category(_, _opts), do: nil

  @impl PhoenixKitEcommerce.ProductSource
  def get_category_by_slug_localized(slug, language, opts \\ []) do
    SlugResolver.find_category_by_slug(slug, language, opts)
  end

  @impl PhoenixKitEcommerce.ProductSource
  def get_category_by_any_slug(slug, opts \\ []) do
    SlugResolver.find_category_by_any_slug(slug, opts)
  end

  @impl PhoenixKitEcommerce.ProductSource
  def product_counts_by_category do
    Product
    |> where([p], not is_nil(p.category_uuid))
    |> group_by([p], p.category_uuid)
    |> select([p], {p.category_uuid, count(p.uuid)})
    |> repo().all()
    |> Map.new()
  rescue
    e ->
      Logger.warning("Failed to load product counts by category: #{inspect(e)}")
      %{}
  end

  # ============================================
  # FILTER AGGREGATION
  # ============================================

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
    category_uuid = Keyword.get(opts, :category_uuid)

    query =
      Product
      |> where([p], p.status == "active")
      |> maybe_filter_category(category_uuid)

    min_price = repo().aggregate(query, :min, :price)
    max_price = repo().aggregate(query, :max, :price)
    {min_price, max_price}
  rescue
    _ -> {nil, nil}
  end

  defp aggregate_single_filter(%{"type" => "price_range"}, category_uuid) do
    {min_price, max_price} = get_price_range_for(category_uuid: category_uuid)
    %{min: min_price, max: max_price}
  end

  defp aggregate_single_filter(%{"type" => "vendor"}, category_uuid) do
    query =
      Product
      |> where([p], p.status == "active" and not is_nil(p.vendor) and p.vendor != "")
      |> maybe_filter_category(category_uuid)
      |> group_by([p], p.vendor)
      |> select([p], %{value: p.vendor, count: count(p.uuid)})
      |> order_by([p], desc: count(p.uuid))

    repo().all(query)
  rescue
    _ -> []
  end

  defp aggregate_single_filter(%{"type" => "metadata_option", "option_key" => key}, category_uuid)
       when is_binary(key) do
    # Query distinct option values from metadata->'_option_values'->key JSONB array
    sql = """
    SELECT val AS value, COUNT(DISTINCT p.uuid) AS count
    FROM phoenix_kit_shop_products p,
         jsonb_array_elements_text(COALESCE(p.metadata->'_option_values'->$1, '[]'::jsonb)) AS val
    WHERE p.status = 'active'
    #{if category_uuid, do: "AND p.category_uuid = $2", else: ""}
    GROUP BY val
    ORDER BY count DESC
    """

    params =
      if category_uuid do
        {:ok, uuid_bin} = Ecto.UUID.dump(category_uuid)
        [key, uuid_bin]
      else
        [key]
      end

    case repo().query(sql, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [value, count] -> %{value: value, count: count} end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp aggregate_single_filter(_filter, _category_uuid), do: []

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, uuid), do: where(query, [p], p.category_uuid == ^uuid)

  # ============================================
  # QUERY FILTER HELPERS
  # ============================================

  defp apply_product_filters(query, opts) do
    query
    |> filter_by_status(Keyword.get(opts, :status))
    |> filter_by_product_type(Keyword.get(opts, :product_type))
    |> filter_by_category(Keyword.get(opts, :category_uuid))
    |> filter_by_product_search(Keyword.get(opts, :search))
    |> filter_by_visible_categories(Keyword.get(opts, :exclude_hidden_categories, false))
    |> filter_by_price_range(Keyword.get(opts, :price_min), Keyword.get(opts, :price_max))
    |> filter_by_vendors(Keyword.get(opts, :vendors))
    |> filter_by_metadata_options(Keyword.get(opts, :metadata_filters))
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: where(query, [p], p.status == ^status)

  defp filter_by_product_type(query, nil), do: query
  defp filter_by_product_type(query, type), do: where(query, [p], p.product_type == ^type)

  defp filter_by_category(query, nil), do: query

  defp filter_by_category(query, uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      where(query, [p], p.category_uuid == ^uuid)
    else
      query
    end
  end

  defp filter_by_visible_categories(query, false), do: query

  defp filter_by_visible_categories(query, true) do
    # Exclude products from categories with status "hidden"
    # Products from "active" and "unlisted" categories are visible
    # Use distinct to avoid duplicates from the left_join
    from(p in query,
      left_join: c in Category,
      on: c.uuid == p.category_uuid,
      where: is_nil(c.uuid) or c.status != "hidden",
      distinct: p.uuid
    )
  end

  defp filter_by_price_range(query, nil, nil), do: query
  defp filter_by_price_range(query, min, nil), do: where(query, [p], p.price >= ^min)
  defp filter_by_price_range(query, nil, max), do: where(query, [p], p.price <= ^max)

  defp filter_by_price_range(query, min, max),
    do: where(query, [p], p.price >= ^min and p.price <= ^max)

  defp filter_by_vendors(query, nil), do: query
  defp filter_by_vendors(query, []), do: query

  defp filter_by_vendors(query, vendors) when is_list(vendors),
    do: where(query, [p], p.vendor in ^vendors)

  defp filter_by_metadata_options(query, nil), do: query
  defp filter_by_metadata_options(query, []), do: query

  defp filter_by_metadata_options(query, filters) when is_list(filters) do
    Enum.reduce(filters, query, fn %{key: key, values: values}, q ->
      where(
        q,
        [p],
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'_option_values'->?, '[]'::jsonb)) elem WHERE elem = ANY(?))",
          p.metadata,
          ^key,
          ^values
        )
      )
    end)
  end

  # Max length for a user-supplied search term. Anything longer is
  # truncated: ILIKE against unindexed JSONB expansions is linear in both
  # pattern and row count, so an unbounded public `?search=` param would be
  # a cheap seq-scan amplifier.
  @max_search_term_length 100

  # Builds a safe `%term%` ILIKE pattern from raw user input: caps the
  # length, strips NUL bytes (Postgres rejects them in text params), and
  # escapes LIKE metacharacters so `%`, `_`, and `\` match literally —
  # a search for "100%" must not match every "100", and SKUs routinely
  # contain underscores.
  defp search_like_pattern(search) do
    escaped =
      search
      |> String.replace(<<0>>, "")
      |> String.slice(0, @max_search_term_length)
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%#{escaped}%"
  end

  defp filter_by_product_search(query, nil), do: query
  defp filter_by_product_search(query, ""), do: query

  defp filter_by_product_search(query, search) do
    search_term = search_like_pattern(search)
    default_lang = Translations.default_language()

    # Search in JSONB localized fields using PostgreSQL operators
    # Searches in default language and falls back to any language match,
    # plus SKU (metadata->>'sku') and tags. Columns are bound through the
    # product binding so the query stays valid when other filters join
    # additional tables (e.g. :exclude_hidden_categories).
    where(
      query,
      [p],
      fragment(
        "(COALESCE(?->>?, '') ILIKE ? OR COALESCE(?->>?, '') ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_each_text(?) WHERE value ILIKE ?) OR EXISTS (SELECT 1 FROM jsonb_each_text(?) WHERE value ILIKE ?) OR COALESCE(?->>'sku', '') ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?, '[]'::jsonb)) AS tag WHERE tag ILIKE ?))",
        p.title,
        ^default_lang,
        ^search_term,
        p.description,
        ^default_lang,
        ^search_term,
        p.title,
        ^search_term,
        p.description,
        ^search_term,
        p.metadata,
        ^search_term,
        p.tags,
        ^search_term
      )
    )
  end

  defp apply_category_filters(query, opts) do
    query
    |> filter_by_parent_uuid(Keyword.get(opts, :parent_uuid, :skip))
    |> filter_by_category_status(Keyword.get(opts, :status, :skip))
    |> filter_by_category_search(Keyword.get(opts, :search))
  end

  defp filter_by_parent_uuid(query, :skip), do: query
  defp filter_by_parent_uuid(query, nil), do: where(query, [c], is_nil(c.parent_uuid))
  defp filter_by_parent_uuid(query, uuid), do: where(query, [c], c.parent_uuid == ^uuid)

  defp filter_by_category_status(query, :skip), do: query
  defp filter_by_category_status(query, nil), do: query

  defp filter_by_category_status(query, status) when is_binary(status) do
    where(query, [c], c.status == ^status)
  end

  defp filter_by_category_status(query, statuses) when is_list(statuses) do
    where(query, [c], c.status in ^statuses)
  end

  defp filter_by_category_search(query, nil), do: query
  defp filter_by_category_search(query, ""), do: query

  defp filter_by_category_search(query, search) do
    search_term = search_like_pattern(search)
    default_lang = Translations.default_language()

    # Search in JSONB localized name field using PostgreSQL operators
    where(
      query,
      [c],
      fragment(
        "(COALESCE(name->>?, '') ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_each_text(name) WHERE value ILIKE ?))",
        ^default_lang,
        ^search_term,
        ^search_term
      )
    )
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
