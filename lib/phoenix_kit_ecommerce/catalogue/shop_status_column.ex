defmodule PhoenixKitEcommerce.Catalogue.ShopStatusColumn do
  @moduledoc """
  The catalogue admin's "Shop status" extension column — surfaces
  `data["ecommerce"]["shop_status"]` next to the catalogue's OWN
  `status` on the item/category tables.

  The owner's complaint: the catalogue's `status` and the shop's
  `shop_status` are two independent signals — an item can be a live
  catalogue entry that is deliberately not for sale — and only the
  catalogue's own `status` showed on screen, so an item could be
  invisible on the storefront for a reason the admin screen never
  surfaced. This column does NOT synchronize the two (that would
  destroy the distinction the owner wants to keep); it shows both, and
  calls out the one disagreement that actually matters: when exactly
  one of "catalogue active" / "shop active" holds, the item is NOT
  visible on the storefront (`ProductSource.Catalogue.Query`'s
  `active_visibility/1` requires both literally `"active"`) for a
  reason that isn't obvious from either field alone.

  Reached only through `PhoenixKitEcommerce.Catalogue.Extension`'s
  `item_columns/0`/`category_columns/0` — see that module's moduledoc
  for the discovery contract, and `PhoenixKitCatalogue.Extension`'s
  typedoc (in the optional `phoenix_kit_catalogue` dependency) for the
  exact `%{id:, label:, render:}` shape this returns. Written
  duck-typed on purpose: nothing here references a `PhoenixKitCatalogue`
  module, so it compiles and behaves identically whether or not that
  dependency, or the extension-column slot it implements, is present at
  all.

  One column definition serves both `item_columns/0` and
  `category_columns/0` — `record.status` and
  `data["ecommerce"]["shop_status"]` mean the same thing (an "active"
  state gating storefront visibility) on both item and category
  records; see `PhoenixKitEcommerce.Catalogue.ItemCommerce` and
  `PhoenixKitEcommerce.Catalogue.CategoryCommerce`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import PhoenixKitWeb.Components.Core.Badge
  import PhoenixKitWeb.Components.Core.Icon

  @unknown "unknown"

  @doc "The `item_columns/0` entry — see this module's moduledoc."
  @spec item_columns() :: [map()]
  def item_columns, do: [column()]

  @doc "The `category_columns/0` entry — see this module's moduledoc."
  @spec category_columns() :: [map()]
  def category_columns, do: [column()]

  defp column, do: %{id: "shop_status", label: &label/0, render: &render/1}

  defp label, do: gettext("Shop status")

  # `record` is the catalogue item or category struct the table is
  # rendering a row for (duck-typed: only `.status`/`.data` are read).
  #
  # `contradiction` is exactly one of "catalogue active" / "shop active"
  # holding — the storefront requires BOTH to be literally `"active"`
  # (`ProductSource.Catalogue.Query.active_visibility/1`), so whenever
  # they disagree the item is invisible for a reason that isn't obvious
  # from either field alone; when they agree (both active, or both not)
  # there's nothing to call out.
  defp render(record) do
    catalogue_status = record |> Map.get(:status) |> normalize()
    shop_status = record |> shop_status_raw() |> normalize()
    catalogue_active? = catalogue_status == "active"
    shop_active? = shop_status == "active"

    cell(%{
      catalogue_status: catalogue_status,
      shop_status: shop_status,
      contradiction: catalogue_active? != shop_active?
    })
  end

  # Absent :data, a nil/non-map :data, an absent/non-map "ecommerce"
  # namespace, an absent "shop_status" key, or a non-binary value all
  # fall through to `nil` here — `normalize/1` turns that into the
  # `"unknown"` ghost badge rather than ever guessing "active".
  defp shop_status_raw(record) do
    with data when is_map(data) <- Map.get(record, :data),
         ecommerce when is_map(ecommerce) <- Map.get(data, "ecommerce"),
         shop_status when is_binary(shop_status) <- Map.get(ecommerce, "shop_status") do
      shop_status
    else
      _ -> nil
    end
  end

  defp normalize(value) when is_binary(value) and value != "", do: value
  defp normalize(_), do: @unknown

  attr :catalogue_status, :string, required: true
  attr :shop_status, :string, required: true
  attr :contradiction, :boolean, required: true

  # No `id` attribute anywhere below: the SAME call renders the row's
  # desktop-table cell AND its mobile-card fact, both present in the DOM
  # on one page load — an id scoped only by the record would duplicate.
  # `data-*` carries everything a test (or future JS) needs instead.
  defp cell(assigns) do
    ~H"""
    <div
      class={["flex items-center gap-1 flex-wrap", @contradiction && "ring-1 ring-warning rounded px-1"]}
      data-shop-status-cell
      data-catalogue-status={@catalogue_status}
      data-shop-status={@shop_status}
      data-contradiction={to_string(@contradiction)}
      title={@contradiction && contradiction_title()}
    >
      <.status_badge status={@catalogue_status} size={:xs} />
      <.status_badge status={@shop_status} size={:xs} />
      <.icon :if={@contradiction} name="hero-exclamation-triangle" class="w-4 h-4 text-warning shrink-0" />
    </div>
    """
  end

  defp contradiction_title do
    gettext(
      "Catalogue status and shop status disagree — this item is not visible on the storefront."
    )
  end
end
