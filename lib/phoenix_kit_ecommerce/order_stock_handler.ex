defmodule PhoenixKitEcommerce.OrderStockHandler do
  @moduledoc """
  Billing's durable order-event handler for this module
  (`PhoenixKitBilling.OrderEvents`, declared by
  `PhoenixKitEcommerce.billing_order_event_handlers/0`).

  When a shop order becomes paid and stock tracking is in force, one goods issue
  takes its goods out of the default warehouse: reason `"sale"`, the order number
  as `external_ref`, the order as a source reference. Billing delivers an event
  at least once and the `external_ref` makes a redelivery harmless. An order paid
  through its invoice fires billing's invoice event as well; only this order
  event writes stock off, so it happens once.

  The money is already taken, so a line stock does not cover never fails the
  job: the goods issue is all or nothing, nothing is posted, and the keeper is
  told once (the mark on the locked order, committed with the notification,
  makes a redelivery silent). The keeper posts the issue by hand, from the order.

  A `:paid` delivered after the order was refunded finds nothing to write off.
  Refunds and cancellations do not give stock back yet.
  """

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.RepoHelper, only: [repo: 0]

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce.Notifications
  alias PhoenixKitEcommerce.StockTracking
  alias PhoenixKitEcommerce.WarehouseSourceKind

  @flagged_key "_shop_stock_short"

  @spec handle_order_event(atom(), map()) :: :ok | {:error, term()}
  def handle_order_event(
        :paid,
        %{status: "paid", metadata: %{"source" => "shop_checkout"}} = order
      ) do
    case StockTracking.location() do
      nil -> :ok
      location -> order |> goods_lines() |> write_off(order, location)
    end
  end

  def handle_order_event(_event, _order), do: :ok

  # What does not ship is not goods; `item_lines/1` leaves out the rest of what
  # no warehouse item stands for and sums the lines of an item.
  defp goods_lines(order) do
    order.line_items
    |> List.wrap()
    |> Enum.reject(&(&1["requires_shipping"] == false))
    |> WarehouseSourceKind.item_lines()
    |> Enum.map(&Map.put(&1, "issued_quantity", &1["required_quantity"]))
  end

  defp write_off([], _order, _location), do: :ok

  defp write_off(lines, order, location) do
    case StockTracking.post_sale(order, lines, location) do
      {:ok, _issue} -> :ok
      {:ok, :already_posted, _issue} -> :ok
      {:error, {:insufficient_stock, short}} -> flag(order.uuid, named(short, lines))
      {:error, reason} -> {:error, reason}
    end
  end

  defp named(short, lines) do
    names = Map.new(lines, &{&1["item_uuid"], &1["name"]})

    Enum.map(short, fn line ->
      %{
        name: names[line.item_uuid],
        requested: units(line.requested),
        available: units(line.available)
      }
    end)
  end

  defp units(quantity), do: quantity |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp flag(order_uuid, short) do
    {:ok, :ok} =
      repo().transaction(fn ->
        order =
          repo().one!(from(o in Billing.Order, where: o.uuid == ^order_uuid, lock: "FOR UPDATE"))

        if order.metadata[@flagged_key] != true do
          :ok = Notifications.order_stock_short(order, short)

          repo().update_all(from(o in Billing.Order, where: o.uuid == ^order_uuid),
            set: [metadata: Map.put(order.metadata, @flagged_key, true)]
          )
        end

        :ok
      end)

    :ok
  end
end
