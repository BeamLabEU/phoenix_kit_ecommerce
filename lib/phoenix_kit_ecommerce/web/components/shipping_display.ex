defmodule PhoenixKitEcommerce.Web.Components.ShippingDisplay do
  @moduledoc """
  What a carrier quote looks like to the buyer, shared by the destination
  picker, the checkout review and the order pages: the delivery time, the
  cash-on-delivery fee, the "estimated price" note and the friendly reason a
  method cannot serve a cart; and on the order pages, the order's shipments.

  The functions take plain values (a `Quote` eta with atom keys or the string
  keyed map an order keeps), so the same lines render for a live cart and for
  a stored order.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import PhoenixKitEcommerce.Web.Helpers, only: [format_price: 2]
  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitEcommerce.Shipments
  alias PhoenixKitEcommerce.Shipping.Codec
  alias PhoenixKitEcommerce.Web.StatusLabels

  attr :id, :string, required: true, doc: "prefix of the ids of the lines"
  attr :eta, :any, default: nil
  attr :cod_fee, :any, default: nil, doc: "Decimal or numeric string"
  attr :currency, :any, default: nil, doc: "currency struct or code of the fee"
  attr :fallback, :boolean, default: false

  @doc """
  The delivery time, the cash-on-delivery fee and the fallback note, each on
  its own line with the id `<id>-eta`, `<id>-cod-fee` and `<id>-fallback`.
  A line without data is not rendered.
  """
  def quote_details(assigns) do
    assigns =
      assigns
      |> assign(:eta_text, eta_text(assigns.eta))
      |> assign(:cod_fee_shown, positive_amount?(assigns.cod_fee))

    ~H"""
    <p :if={@eta_text} id={"#{@id}-eta"} class="flex items-center gap-1.5 text-sm">
      <.icon name="hero-clock" class="w-4 h-4 shrink-0 text-base-content/60" />
      <span>{@eta_text}</span>
    </p>
    <p
      :if={@cod_fee_shown}
      id={"#{@id}-cod-fee"}
      class="flex items-start gap-1.5 text-sm text-base-content/70"
    >
      <.icon name="hero-banknotes" class="w-4 h-4 mt-0.5 shrink-0" />
      <span>
        {gettext("Cash-on-delivery fee %{fee}, paid by the recipient to the carrier",
          fee: format_price(@cod_fee, @currency)
        )}
      </span>
    </p>
    <p
      :if={@fallback}
      id={"#{@id}-fallback"}
      class="flex items-start gap-1.5 text-sm text-base-content/70"
    >
      <.icon name="hero-information-circle" class="w-4 h-4 mt-0.5 shrink-0 text-warning" />
      <span>{gettext("Estimated price: the carrier did not respond")}</span>
    </p>
    """
  end

  attr :item, :map, required: true, doc: "the shipping line of the order"
  attr :metadata, :map, required: true, doc: "the metadata of the order"

  @doc """
  What an order remembers of a carrier-priced shipping line: where it goes
  (`id="order-shipping-destination"`) and the lines of `quote_details/1` with
  the prefix `order-shipping`. Nothing for an ordinary method's line.
  """
  def order_shipping_details(assigns) do
    entry = Codec.get(assigns.metadata, :shipping_quote)
    stored = Codec.get(entry, :quote)

    assigns =
      assigns
      |> assign(:label, assigns.item["destination_label"])
      |> assign(:eta, assigns.item["eta"])
      |> assign(:cod_fee, Codec.get(stored, :cod_fee))
      |> assign(:currency, Codec.get(stored, :currency))
      |> assign(:fallback, Codec.get(entry, :status) == "fallback")

    ~H"""
    <div
      :if={@label || @eta || @fallback || positive_amount?(@cod_fee)}
      id="order-shipping-details"
      class="mt-1 space-y-1 text-base-content/70"
    >
      <p :if={@label} id="order-shipping-destination" class="flex items-start gap-1.5 text-sm">
        <.icon name="hero-map-pin" class="w-4 h-4 mt-0.5 shrink-0" />
        <span class="break-words">{@label}</span>
      </p>
      <.quote_details
        id="order-shipping"
        eta={@eta}
        cod_fee={@cod_fee}
        currency={@currency}
        fallback={@fallback}
      />
    </div>
    """
  end

  attr :shipments, :list,
    required: true,
    doc: "the order's shipments the buyer is shown, newest first (`Shipments.buyer_shipments/1`)"

  @doc """
  The order's shipments for the buyer, one block each (`id="order-shipment-<uuid>"`):
  the carrier, the status, the tracking number and the tracking link, which is
  rendered only when it is a web address (`Shipments.web_url/1`). Nothing
  without a shipment.
  """
  def order_shipments(assigns) do
    ~H"""
    <div :if={@shipments != []} id="order-shipments" class="space-y-3">
      <div
        :for={shipment <- @shipments}
        id={"order-shipment-#{shipment.uuid}"}
        class="flex items-start gap-3 text-sm"
      >
        <.icon name="hero-truck" class="w-5 h-5 mt-0.5 shrink-0 text-base-content/60" />
        <div class="min-w-0 space-y-0.5">
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-medium">{Shipments.carrier_name(shipment)}</span>
            <span class="badge badge-ghost badge-sm">{StatusLabels.shipment(shipment.status)}</span>
          </div>
          <div :if={shipment.tracking_number} class="text-base-content/70">
            {gettext("Tracking number")}:
            <span class="font-mono break-all">{shipment.tracking_number}</span>
          </div>
          <.tracking_link shipment={shipment} />
        </div>
      </div>
    </div>
    """
  end

  attr :shipment, :map, required: true

  defp tracking_link(assigns) do
    assigns = assign(assigns, :url, Shipments.web_url(assigns.shipment.tracking_url))

    ~H"""
    <a
      :if={@url}
      id={"order-shipment-#{@shipment.uuid}-tracking"}
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      class="link link-primary inline-flex items-center gap-1"
    >
      {gettext("Track your parcel")}
      <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
    </a>
    """
  end

  @doc """
  The delivery time as a sentence: a date ("by 12.10.2026"), a range of days
  or a number of days. `nil` when the carrier gave none.
  """
  @spec eta_text(term()) :: String.t() | nil
  def eta_text(eta) when is_map(eta) do
    date = eta |> Codec.get(:date) |> Codec.date()
    min = eta |> Codec.get(:min_days) |> Codec.integer()
    max = eta |> Codec.get(:max_days) |> Codec.integer()

    cond do
      date -> gettext("Delivery by %{date}", date: UtilsDate.format_date_with_user_format(date))
      min && max && min != max -> days_range(min, max)
      days = max || min -> days_count(days)
      true -> nil
    end
  end

  def eta_text(_other), do: nil

  defp days_range(min, max) do
    ngettext("Delivery in %{min}–%{max} day", "Delivery in %{min}–%{max} days", max,
      min: min,
      max: max
    )
  end

  defp days_count(days) do
    ngettext("Delivery in %{count} day", "Delivery in %{count} days", days)
  end

  @doc """
  The reason (`CartQuote.error_reason/1` form) a method cannot serve a cart,
  in words the buyer understands.
  """
  @spec unavailable_text(term()) :: String.t()
  def unavailable_text("too_heavy"),
    do: gettext("This delivery method is not available: the order is too heavy for it.")

  def unavailable_text("too_large"),
    do: gettext("This delivery method is not available: the order is too large for it.")

  def unavailable_text("service_unavailable"),
    do: gettext("This delivery service is not available right now.")

  def unavailable_text("unsupported_destination"),
    do: gettext("This delivery method does not deliver to the chosen place.")

  def unavailable_text(_other),
    do: gettext("This delivery method is not available for this order.")

  @doc "Whether `amount` (Decimal, number or numeric string) is greater than zero."
  @spec positive_amount?(term()) :: boolean()
  def positive_amount?(amount) do
    case Codec.decimal(amount) do
      %Decimal{} = decimal -> Decimal.compare(decimal, 0) == :gt
      nil -> false
    end
  end
end
