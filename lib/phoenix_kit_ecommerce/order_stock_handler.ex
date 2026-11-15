defmodule PhoenixKitEcommerce.OrderStockHandler do
  @moduledoc """
  Billing's durable order-event handler for this module
  (`PhoenixKitBilling.OrderEvents`, declared by
  `PhoenixKitEcommerce.billing_order_event_handlers/0`).

  ## Paid

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

  A write-off that takes an item to or below its Warehouse minimum tells the
  keeper too (`StockTracking.crossed_minimum/1`), once per crossing. That
  reminder is best-effort and follows the posting: a delivery that finds the
  sale already posted sends none.

  A `:paid` delivered after the order was refunded finds nothing to write off.

  ## Refunded

  Billing moves a paid order only to `"refunded"` (a paid order is never
  cancelled), and a refund does not say whether the goods came back. When the
  order's sale was posted, `StockTracking.refund_action/0` decides: `"notify"`
  (the default) tells the keeper once, `"receipt"` posts a goods receipt that
  puts the same quantities back where they were taken from, idempotent on
  `"<order number>/return"`. A receipt Warehouse refuses tells the keeper
  instead, so the job never retries against a refusal that will not change.
  An order that was short when paid had nothing written off automatically; the
  keeper may have issued it by hand, so it is told whatever the setting.

  `:cancelled` changes nothing: only an unpaid order is cancelled, and nothing
  was written off for it.
  """

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.RepoHelper, only: [repo: 0]

  require Logger

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.Notifications
  alias PhoenixKitEcommerce.StockTracking
  alias PhoenixKitEcommerce.WarehouseSourceKind

  @flagged_key "_shop_stock_short"
  @refund_told_key "_shop_refund_stock_told"

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

  def handle_order_event(
        :refunded,
        %{status: "refunded", metadata: %{"source" => "shop_checkout"} = metadata} = order
      ) do
    case StockTracking.sale_issue(order.order_number) do
      nil when is_map_key(metadata, @flagged_key) -> tell_refund(order, :not_written_off)
      nil -> :ok
      issue -> give_back(order, issue, StockTracking.refund_action())
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
      {:ok, issue} -> after_posting(issue, :issued)
      {:ok, :already_posted, _issue} -> :ok
      {:error, {:insufficient_stock, short}} -> flag(order.uuid, named(short, lines))
      {:error, reason} -> {:error, reason}
    end
  end

  # Open product pages show the new stock; the reminder follows a fresh
  # write-off only.
  defp after_posting(document, change) do
    Enum.each(document.lines, &broadcast_stock(&1["item_uuid"], change))

    if change == :issued,
      do: document |> StockTracking.crossed_minimum() |> Notifications.stock_low()

    :ok
  end

  defp broadcast_stock(item_uuid, change) do
    Events.broadcast_inventory_updated(item_uuid, change)
  rescue
    error -> Logger.warning("[Shop] stock change not broadcast: #{Exception.message(error)}")
  end

  defp give_back(order, issue, "receipt") do
    case StockTracking.post_return(order, issue) do
      {:ok, receipt} ->
        after_posting(receipt, :returned)

      {:ok, :already_posted, _receipt} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Shop] the return of refunded order #{order.order_number} was refused: #{inspect(reason)}"
        )

        tell_refund(order, {:written_off, issued(issue)})
    end
  end

  defp give_back(order, issue, _notify), do: tell_refund(order, {:written_off, issued(issue)})

  defp issued(issue) do
    Enum.map(issue.lines, &%{name: &1["name"], quantity: units(&1["issued_quantity"])})
  end

  defp tell_refund(order, what) do
    once(order.uuid, @refund_told_key, &Notifications.order_refunded_stock(&1, what))
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

  defp units(quantity),
    do: quantity |> Decimal.new() |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp flag(order_uuid, short) do
    once(order_uuid, @flagged_key, &Notifications.order_stock_short(&1, short))
  end

  # Tells once per order and mark: the mark is written on the locked order in
  # the transaction that creates the notification, so a redelivery that finds
  # it tells nobody, and a failed notification leaves no mark behind.
  defp once(order_uuid, mark, tell) do
    {:ok, :ok} =
      repo().transaction(fn ->
        order =
          repo().one!(from(o in Billing.Order, where: o.uuid == ^order_uuid, lock: "FOR UPDATE"))

        if order.metadata[mark] != true do
          :ok = tell.(order)

          repo().update_all(from(o in Billing.Order, where: o.uuid == ^order_uuid),
            set: [metadata: Map.put(order.metadata, mark, true)]
          )
        end

        :ok
      end)

    :ok
  end
end
