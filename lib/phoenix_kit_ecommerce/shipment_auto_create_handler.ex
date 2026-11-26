defmodule PhoenixKitEcommerce.ShipmentAutoCreateHandler do
  @moduledoc """
  Billing's durable order-event handler that registers a paid order's shipment
  with the carrier on its own (`PhoenixKitBilling.OrderEvents`, declared by
  `PhoenixKitEcommerce.billing_order_event_handlers/0`), while
  `PhoenixKitEcommerce.shipping_auto_create?/0` is on (off by default).

  On `:paid` it reads the order again and does nothing unless it is still
  `paid`, its shipping method's provider can register shipments
  (`create_shipment/2`) and it has no shipment yet, of any status. Then it
  takes the admin's path, `Shipments.begin_shipment/2` and
  `Shipments.submit_shipment/2`; the partial unique index refuses a second
  live shipment to a delivery that runs at the same time.

  Billing delivers an event at least once. Once a shipment row exists the
  handler answers `:ok`, whatever the carrier said, so a retried job never
  calls the carrier a second time: a `failed` or `unknown` shipment waits for
  the admin on the Shipments page, a stuck `creating` one is swept to
  `unknown`. Only a refusal written before any row (the provider's lookups
  failing) is `{:error, _}`, for the job to retry. An order the carrier would
  not take as it is (no listed pickup point, a destination it rejects) is
  logged and left on the page's "To ship" list.

  It runs in billing's job, never in a caller's transaction
  (`Shipments.submit_shipment/2` refuses one), and logs the Activity of the
  registration itself, as the system: the admin page's logging does not run
  here.
  """

  require Logger

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.Shipment
  alias PhoenixKitEcommerce.Shipments

  # The order has nothing a carrier could register.
  @not_shippable [:no_shipping_method, :shipments_not_supported, :order_not_paid, :not_found]

  @spec handle_order_event(atom(), map()) :: :ok | {:error, term()}
  def handle_order_event(
        :paid,
        %{status: "paid", metadata: %{"source" => "shop_checkout"}} = order
      ) do
    if Shop.shipping_auto_create?(), do: register(order.uuid), else: :ok
  end

  def handle_order_event(_event, _order), do: :ok

  defp register(order_uuid) do
    case Shipments.list_order_shipments(order_uuid) do
      [] -> begin(order_uuid)
      [_ | _] -> :ok
    end
  end

  defp begin(order_uuid) do
    case Shipments.begin_shipment(order_uuid) do
      {:ok, shipment} ->
        submit(shipment)

      {:error, reason} when reason in @not_shippable ->
        :ok

      {:error, :live_shipment_exists} ->
        :ok

      # Kept by Oban in the job's errors: the tag only, never the carrier's text.
      {:error, {:destination_unverified, reason}} ->
        {:error, {:destination_unverified, reason_text(reason)}}

      {:error, reason} ->
        Logger.warning(
          "[Shop] the shipment of order #{order_uuid} was not registered on payment: " <>
            reason_text(reason)
        )

        :ok
    end
  end

  # The row exists from here on: whatever the attempt answers, a retry must
  # not reach the carrier again.
  defp submit(shipment) do
    case Shipments.submit_shipment(shipment) do
      {:ok, %Shipment{} = submitted} -> log(submitted)
      {:error, _reason} -> :ok
    end

    :ok
  end

  defp log(%Shipment{} = shipment) do
    Activity.log("shop.shipment_created",
      mode: "auto",
      actor_role: "system",
      resource_type: "shipment",
      resource_uuid: shipment.uuid,
      target_uuid: shipment.order_uuid,
      metadata: %{"status" => shipment.status, "provider" => shipment.provider}
    )
  end

  # The reason's tag only: a destination refusal quotes the carrier's text.
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_text(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: reason |> elem(0) |> Atom.to_string()

  defp reason_text(_reason), do: "error"
end
