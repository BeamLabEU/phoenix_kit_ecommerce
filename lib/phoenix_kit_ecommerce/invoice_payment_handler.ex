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

  Delivery is recorded on the locked order in the same transaction as the
  notification, so redelivery cannot confirm it twice. This internal marker
  does not change the order's business revision or modification time.
  """

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.RepoHelper, only: [repo: 0]

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce.Notifications
  alias PhoenixKitEcommerce.OnlinePayment

  @unpaid ~w(draft pending confirmed)
  @notified_key "_shop_payment_notified"

  @spec handle_invoice_event(atom(), map()) :: :ok | {:error, term()}
  def handle_invoice_event(:paid, %{order_uuid: order_uuid}) when is_binary(order_uuid) do
    repo().transaction(fn ->
      order =
        repo().one(from(o in Billing.Order, where: o.uuid == ^order_uuid, lock: "FOR UPDATE"))

      case handle_order(order) do
        :ok -> :ok
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_invoice_event(_event, _invoice), do: :ok

  defp handle_order(%{metadata: %{"source" => "shop_checkout"}} = order),
    do: notify_when_paid(order)

  defp handle_order(_order), do: :ok

  # Billing records an admin "Mark paid" on the invoice and moves the order
  # afterwards, so the event can arrive first: ask for a retry (the worker
  # redelivers) rather than drop the buyer's message. A terminal state that
  # is not "paid" (cancelled, refunded) is final and ends the job.
  defp notify_when_paid(%{status: "paid"} = order) do
    if OnlinePayment.required?(order) and order.metadata[@notified_key] != true do
      with :ok <- Notifications.order_paid(order, language: order.metadata["checkout_language"]) do
        repo().update_all(from(o in Billing.Order, where: o.uuid == ^order.uuid),
          set: [metadata: Map.put(order.metadata, @notified_key, true)]
        )

        :ok
      end
    else
      :ok
    end
  end

  defp notify_when_paid(%{status: status} = order) when status in @unpaid do
    if OnlinePayment.required?(order), do: {:error, :order_not_paid_yet}, else: :ok
  end

  defp notify_when_paid(_order), do: :ok
end
