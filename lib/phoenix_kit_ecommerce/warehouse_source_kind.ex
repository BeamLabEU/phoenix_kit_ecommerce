defmodule PhoenixKitEcommerce.WarehouseSourceKind do
  @moduledoc """
  The warehouse source kind `"shop_order"`: a shop order (a billing order
  placed through the storefront checkout) as the basis of a warehouse
  document (spec 6.3, decision D10).

  `PhoenixKitEcommerce.warehouse_source_kinds/0` returns `kinds/0`, and the
  Warehouse module merges it with the kinds a host configured itself
  (`PhoenixKitWarehouse.SourceKinds.list_kinds/0`), so no host configuration
  changes. The three callbacks have the shapes `SourceKinds` documents:

    * `search/1` - candidates for a picker: `[%{uuid, label, extra}]`;
    * `resolve/1` - `%{label, path}` for an existing reference, or `:error`;
    * `build_lines/2` - the order's product lines for an internal order.

  An order counts as a shop order when it was placed by the storefront
  checkout (`metadata["source"] == "shop_checkout"`); an order a person typed
  into billing by hand is not offered. Labels show the order number and the
  status, never the customer: the warehouse screens are not the place for
  personal data, and nothing here reads the billing profile.
  """

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.ProductSource

  @kind "shop_order"
  @source "shop_checkout"
  @search_limit 20

  @doc "The kind name stored in a document's `source_refs` (`\"type\"`)."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  The kind declaration `SourceKinds` merges. A literal list built from this
  module's own functions: it runs for every rendered reference, so it must
  not query.
  """
  @spec kinds() :: [map()]
  def kinds do
    [
      %{
        kind: @kind,
        label: gettext("Shop order"),
        search: {__MODULE__, :search, []},
        resolve: {__MODULE__, :resolve, []},
        build_lines: {__MODULE__, :build_lines, []}
      }
    ]
  end

  @doc "Shop orders whose number contains `query`, newest first. Empty while the shop is off."
  @spec search(String.t()) :: [%{uuid: String.t(), label: String.t(), extra: map()}]
  def search(query) when is_binary(query) do
    if PhoenixKitEcommerce.enabled?() do
      pattern = ProductSource.search_like_pattern(query)

      RepoHelper.repo().all(
        from(o in Order,
          where: fragment("?->>'source'", o.metadata) == ^@source,
          where: ilike(o.order_number, ^pattern),
          order_by: [desc: o.inserted_at],
          limit: ^@search_limit,
          select: struct(o, [:uuid, :order_number, :status, :total, :currency])
        )
      )
      |> Enum.map(&%{uuid: &1.uuid, label: label(&1), extra: %{status: &1.status}})
    else
      []
    end
  end

  @doc "`%{label, path}` of an existing shop order, or `:error`."
  @spec resolve(String.t()) :: %{label: String.t(), path: String.t()} | :error
  def resolve(uuid) when is_binary(uuid) do
    case fetch(uuid) do
      %Order{} = order ->
        %{label: label(order), path: Routes.path("/admin/billing/orders/#{order.uuid}")}

      nil ->
        :error
    end
  end

  @doc """
  The product lines of a shop order, as an internal order imports them:
  `item_uuid`, `name`, `sku`, `unit`, `catalogue_uuid` and `required_quantity`.
  A line without a catalogue item (a shipping line, a legacy product) is left
  out. `:error` when the order does not exist.
  """
  @spec build_lines(String.t(), String.t()) :: {:ok, [map()]} | :error
  def build_lines(uuid, _actor_uuid) when is_binary(uuid) do
    case fetch(uuid) do
      %Order{line_items: line_items} ->
        lines = Enum.filter(line_items, &product_line?/1)
        facts = lines |> Enum.map(& &1["catalogue_item_uuid"]) |> Enum.uniq() |> catalogue_facts()

        {:ok, Enum.map(lines, &line(&1, facts))}

      nil ->
        :error
    end
  end

  # `unit` and the catalogue of each item, in one query. Read by table name:
  # the catalogue is an optional dependency, so its schema module is not
  # referenced here, and nothing is queried when it is not loaded.
  defp catalogue_facts([]), do: %{}

  defp catalogue_facts(item_uuids) do
    if Code.ensure_loaded?(PhoenixKitCatalogue.Schemas.Item) do
      RepoHelper.repo().all(
        from(i in "phoenix_kit_cat_items",
          where: i.uuid in type(^item_uuids, {:array, Ecto.UUID}),
          select: {type(i.uuid, Ecto.UUID), i.unit, type(i.catalogue_uuid, Ecto.UUID)}
        )
      )
      |> Map.new(fn {uuid, unit, catalogue_uuid} ->
        {uuid, %{unit: unit, catalogue_uuid: catalogue_uuid}}
      end)
    else
      %{}
    end
  end

  defp fetch(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Order{metadata: %{"source" => @source}} = order <- RepoHelper.repo().get(Order, uuid) do
      order
    else
      _ -> nil
    end
  end

  defp product_line?(line),
    do: line["type"] == "product" and is_binary(line["catalogue_item_uuid"])

  defp line(line, facts) do
    fact = Map.get(facts, line["catalogue_item_uuid"], %{})

    %{
      "item_uuid" => line["catalogue_item_uuid"],
      "name" => line["name"],
      "sku" => line["sku"],
      "unit" => fact[:unit],
      "catalogue_uuid" => fact[:catalogue_uuid],
      "required_quantity" => to_string(line["quantity"] || 0)
    }
  end

  defp label(%Order{order_number: number, uuid: uuid, status: status}) do
    "#{number || String.slice(uuid, 0, 8)} (#{status})"
  end
end
