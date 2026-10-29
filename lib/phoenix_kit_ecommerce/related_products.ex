defmodule PhoenixKitEcommerce.RelatedProducts do
  @moduledoc """
  The "You may also like" list of a product: other products the merchant
  picked by hand (upsells), shown on the product page.

  ## Storage

  A list of product uuids under `related_product_uuids` (upsells, the product
  page) or `cross_sell_product_uuids` (the cart). No column and no migration;
  the product form owns the key (see `ProductForm`). The order is the merchant's. The list is data a form
  submits, so every reader goes through `normalize/2`: only well-formed uuids,
  each once, never the product itself, at most `max_items/0`. A stored value of
  any other shape reads as an empty list.

  ## What the shopper sees

  `for_product/2` resolves the list to products a shopper may see (status
  `active`, category not `hidden`, `PhoenixKitEcommerce.Availability`), in the
  merchant's order, at most `limit/0` of them. An id that points to a deleted,
  draft or hidden product is skipped silently; nothing is cleaned up on read.
  When nothing is left and `fallback/0` is `:category`, the newest listed
  products of the product's own category stand in. The fallback is off by
  default, so a shop that never sets a list renders exactly what it did.

  Both product sources store the lists: a legacy product under its `metadata`,
  a catalogue item under `data["ecommerce"]` (the catalogue view puts them in
  the view-struct's `metadata` under the same keys). The cart's cross-sell
  list (`:cross_sell`) is stored the same way and read by `cross_sells/2`.

  ## Settings

  Read through this module, never directly:

    * `shop_related_fallback` - `"off"` (default) or `"category"`
    * `shop_related_limit` - how many products the block shows, 1..12
      (default 4)
  """

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.Availability
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue
  alias PhoenixKitEcommerce.ProductSource.Legacy

  @keys %{related: "related_product_uuids", cross_sell: "cross_sell_product_uuids"}
  @max_items 12
  @default_limit 4

  @typedoc "`:related` (the product page) or `:cross_sell` (the cart)."
  @type kind :: :related | :cross_sell

  @doc "The key a list is stored under (`metadata` of a legacy product, `data[\"ecommerce\"]` of an item)."
  @spec metadata_key(kind()) :: String.t()
  def metadata_key(kind \\ :related), do: Map.fetch!(@keys, kind)

  @doc "The most products one list may hold."
  @spec max_items() :: pos_integer()
  def max_items, do: @max_items

  @doc """
  The product's stored list of `kind`, normalized.
  """
  @spec uuids(term(), kind()) :: [String.t()]
  def uuids(product, kind \\ :related)

  def uuids(%{metadata: metadata} = product, kind) when is_map(metadata) do
    metadata |> Map.get(metadata_key(kind)) |> normalize(Map.get(product, :uuid))
  end

  def uuids(_other, _kind), do: []

  @doc """
  Keeps the well-formed, distinct uuids of `value` in their order, drops
  `own_uuid` (a product does not relate to itself) and stops at `max_items/0`.
  Anything that is not a list, and every entry that is not a uuid string
  (a number, a boolean, a map), is dropped.
  """
  @spec normalize(term(), term()) :: [String.t()]
  def normalize(value, own_uuid \\ nil)

  def normalize(list, own_uuid) when is_list(list) do
    own = cast(own_uuid)

    list
    |> Enum.flat_map(fn entry -> List.wrap(cast(entry)) end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == own))
    |> Enum.take(@max_items)
  end

  def normalize(_other, _own_uuid), do: []

  defp cast(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp cast(_value), do: nil

  @doc """
  The products to show under `product`, ready for the storefront. Options:
  `:limit` (default `limit/0`), `:language`.
  """
  @spec for_product(term(), keyword()) :: [PhoenixKitEcommerce.Product.t()]
  def for_product(product, opts \\ [])

  def for_product(%{uuid: uuid} = product, opts) when is_binary(uuid) do
    limit = Keyword.get(opts, :limit, limit())

    case product |> uuids(:related) |> listed(opts) |> available(limit) do
      [] -> fallback_products(product, limit, opts)
      shown -> shown
    end
  end

  def for_product(_other, _opts), do: []

  @doc """
  The cross-sells of a cart: the `:cross_sell` lists of `cart_products`
  together, in cart order, leaving out `:exclude` (uuids already in the cart)
  and anything a shopper may not see. Options: `:exclude`, `:limit` (default
  `limit/0`), `:language`.
  """
  @spec cross_sells([term()], keyword()) :: [PhoenixKitEcommerce.Product.t()]
  def cross_sells(cart_products, opts \\ []) when is_list(cart_products) do
    exclude = Keyword.get(opts, :exclude, [])
    limit = Keyword.get(opts, :limit, limit())

    cart_products
    |> Enum.flat_map(&uuids(&1, :cross_sell))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in exclude))
    |> listed(opts)
    |> available(limit)
  end

  # The listed products of `ids`, in the order of `ids`, read from the
  # active product source.
  defp listed(ids, opts) do
    case ProductSource.current() do
      Legacy -> Legacy.list_listed_by_ids(ids)
      Catalogue -> Catalogue.list_listed_by_ids(ids, language: Keyword.get(opts, :language))
    end
  end

  defp fallback_products(%{category_uuid: category, uuid: uuid}, limit, opts)
       when is_binary(category) do
    if fallback() == :category do
      # More than `limit` are read: some may be unavailable.
      category |> in_category(uuid, limit * 3, opts) |> available(limit)
    else
      []
    end
  end

  defp fallback_products(_product, _limit, _opts), do: []

  defp in_category(category, uuid, count, opts) do
    case ProductSource.current() do
      Legacy ->
        Legacy.list_listed_in_category(category, uuid, count)

      Catalogue ->
        Catalogue.list_listed_in_category(category, uuid, count,
          language: Keyword.get(opts, :language)
        )
    end
  end

  defp available(products, limit),
    do: products |> Enum.filter(&Availability.available?/1) |> Enum.take(limit)

  @doc """
  What stands in when a product has no list left to show: `:off` (default) or
  `:category`. A stored value neither reader knows counts as `:off`.
  """
  @spec fallback() :: :off | :category
  def fallback do
    case Settings.get_setting_cached("shop_related_fallback", "off") do
      "category" -> :category
      _ -> :off
    end
  end

  @doc "How many products the block shows (`shop_related_limit`), 1..#{@max_items}."
  @spec limit() :: pos_integer()
  def limit do
    with value when is_binary(value) <-
           Settings.get_setting_cached("shop_related_limit", to_string(@default_limit)),
         {n, ""} when n in 1..@max_items <- Integer.parse(value) do
      n
    else
      _ -> @default_limit
    end
  end
end
