defmodule PhoenixKitEcommerce.OrderEmailHandler do
  @moduledoc """
  Billing's durable order-event handler for the emails of a paid order
  (`PhoenixKitBilling.OrderEvents`, declared by
  `PhoenixKitEcommerce.billing_order_event_handlers/0`).

  It only queues them (`PhoenixKitEcommerce.OrderEmails`), so a delivered event
  never waits for a mail server. A `:paid` delivered after the order was refunded
  sends nothing.
  """

  alias PhoenixKitEcommerce.OrderEmails

  @spec handle_order_event(atom(), map()) :: :ok | {:error, term()}
  def handle_order_event(
        :paid,
        %{status: "paid", metadata: %{"source" => "shop_checkout"}} = order
      ),
      do: OrderEmails.order_paid(order)

  def handle_order_event(_event, _order), do: :ok
end
