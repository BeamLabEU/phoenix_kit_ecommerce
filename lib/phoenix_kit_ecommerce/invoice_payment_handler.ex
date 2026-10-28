defmodule PhoenixKitEcommerce.InvoicePaymentHandler do
  @moduledoc """
  Billing's durable invoice-event handler for this module
  (`PhoenixKitBilling.InvoiceEvents`, declared by
  `PhoenixKitEcommerce.billing_invoice_event_handlers/0`).

  When the invoice of an online shop order is paid, the buyer hears that the
  order is confirmed: that message is held back at checkout while the order
  waits for its payment (`PhoenixKitEcommerce.Notifications.order_placed/2`).
  Billing delivers the event at least once and survives a restart, which is
  why this is not a PubSub subscription.
  """

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce.Notifications
  alias PhoenixKitEcommerce.OnlinePayment

  @unpaid ~w(draft pending confirmed)

  @spec handle_invoice_event(atom(), map()) :: :ok | {:error, :order_not_paid_yet}
  def handle_invoice_event(:paid, %{order_uuid: order_uuid}) when is_binary(order_uuid) do
    case Billing.get_order_by_uuid(order_uuid) do
      %{metadata: %{"source" => "shop_checkout"}} = order ->
        notify_when_paid(order)

      _ ->
        :ok
    end
  end

  def handle_invoice_event(_event, _invoice), do: :ok

  # Billing records an admin "Mark paid" on the invoice and moves the order
  # afterwards, so the event can arrive first: ask for a retry (the worker
  # redelivers) rather than drop the buyer's message. A terminal state that
  # is not "paid" (cancelled, refunded) is final and ends the job.
  defp notify_when_paid(%{status: "paid"} = order) do
    if OnlinePayment.online?(order), do: Notifications.order_paid(order)
    :ok
  end

  defp notify_when_paid(%{status: status} = order) when status in @unpaid do
    if OnlinePayment.online?(order), do: {:error, :order_not_paid_yet}, else: :ok
  end

  defp notify_when_paid(_order), do: :ok
end
