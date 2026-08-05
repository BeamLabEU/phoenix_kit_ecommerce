defmodule PhoenixKitEcommerce.Notifications do
  @moduledoc """
  Shop notifications: who hears about an order or an import, and when.

  Sends go through core's notification layer, so each recipient's own
  per-type preferences and delivery channels (in-app inbox, email,
  Telegram, digest cadence) apply. This module only decides the audience
  and the copy.

  ## Recipients

  `admin_recipients/0` unions three sources, because no single one is
  complete:

    * holders of the relevant permission key (`users_with_permission/1`)
    * **Owner-role holders**, whose access is implicit and who therefore
      have no permission rows at all
    * holders of the `"*"` superadmin key, likewise absent from a
      key-specific query

  A resolver that queried only the first would miss the primary operator
  of a default install — the person most likely to want the notification.

  ## Failure is never fatal

  Every send is wrapped: a notification is a message *about* a committed
  fact, and must not be able to undo it. Order placement in particular
  runs this after the conversion transaction commits.
  """

  require Logger

  alias PhoenixKit.Notifications
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @order_action "shop.order_placed"
  @customer_order_action "shop.order_confirmed"
  @import_completed_action "shop.import_completed"
  @import_failed_action "shop.import_failed"

  @doc """
  Notifies shop operators that an order was placed, and (separately) the
  customer that theirs was confirmed.

  Best-effort by construction — see the module doc.
  """
  def order_placed(order) do
    safely(fn ->
      notify_admins_of_order(order)
      notify_customer_of_order(order)
    end)
  end

  defp notify_admins_of_order(order) do
    recipients = admin_recipients("shop.manage_carts")

    # Never notify the buyer in the ADMIN fan-out; they get their own
    # message with customer-facing copy and a link they can open.
    recipients = Enum.reject(recipients, &(&1 == order.user_uuid))

    Notifications.create_many(recipients, %{
      action: @order_action,
      text: "New order #{order.order_number} — #{order_total(order)}",
      icon: "hero-shopping-bag",
      link: Routes.path("/admin/shop/carts")
    })
  end

  # Only a real, confirmed account gets an in-app notification: guest
  # checkout creates an unconfirmed placeholder user whose channel is the
  # transactional confirmation email, and sending both would double-mail
  # someone who has not even confirmed an address yet.
  defp notify_customer_of_order(%{user_uuid: nil}), do: :ok

  defp notify_customer_of_order(order) do
    case PhoenixKit.Users.Auth.get_user(order.user_uuid) do
      %{confirmed_at: confirmed} = _user when not is_nil(confirmed) ->
        Notifications.create(%{
          recipient_uuid: order.user_uuid,
          action: @customer_order_action,
          text: "Your order #{order.order_number} is confirmed",
          icon: "hero-check-circle",
          link: Routes.path("/dashboard/orders/#{order.uuid}")
        })

      _unconfirmed_or_missing ->
        :ok
    end
  end

  @doc """
  Notifies the admin who started an import that it finished.

  Job-level only: one message per import carrying aggregate counts, never
  one per row — a 10k-row import must not produce 10k notifications.
  """
  def import_completed(import_log, stats) do
    safely(fn ->
      notify_initiator(import_log, %{
        action: @import_completed_action,
        text: import_summary(import_log, stats),
        icon: "hero-check-circle"
      })
    end)
  end

  @doc """
  Notifies the initiator that an import failed.

  Call ONLY on the terminal attempt: Oban retries a failed job, and
  notifying on every attempt turns one transient failure into three
  alerts followed by a success.
  """
  def import_failed(import_log, reason) do
    safely(fn ->
      notify_initiator(import_log, %{
        action: @import_failed_action,
        text: "Import failed: #{truncate(to_string(reason), 120)}",
        icon: "hero-exclamation-triangle"
      })
    end)
  end

  # Import logs predate the user_uuid column; there is nobody to tell.
  defp notify_initiator(%{user_uuid: nil}, _attrs), do: :ok

  defp notify_initiator(import_log, attrs) do
    Notifications.create(
      Map.merge(attrs, %{
        recipient_uuid: import_log.user_uuid,
        link: Routes.path("/admin/shop/imports/#{import_log.uuid}")
      })
    )
  end

  @doc """
  Everyone who should hear about shop operations: holders of `key`,
  unioned with Owner-role holders and `"*"` superadmins.
  """
  def admin_recipients(key) do
    (Permissions.users_with_permission(key) ++
       Permissions.users_with_permission("*") ++
       Roles.users_with_role("Owner"))
    |> Enum.map(&user_uuid/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    error ->
      Logger.warning("[Shop] could not resolve notification recipients: #{inspect(error)}")
      []
  end

  defp user_uuid(%{uuid: uuid}), do: uuid
  defp user_uuid(%{user_uuid: uuid}), do: uuid
  defp user_uuid(uuid) when is_binary(uuid), do: uuid
  defp user_uuid(_), do: nil

  defp order_total(%{total: total, currency: currency}) when not is_nil(total) do
    "#{Decimal.round(total, 2)} #{currency}"
  end

  defp order_total(_), do: ""

  defp import_summary(import_log, stats) when is_map(stats) do
    created = Map.get(stats, :created) || Map.get(stats, "created") || 0
    updated = Map.get(stats, :updated) || Map.get(stats, "updated") || 0
    failed = Map.get(stats, :failed) || Map.get(stats, "failed") || 0

    "Import finished: #{created} created, #{updated} updated, #{failed} failed" <>
      import_name(import_log)
  end

  defp import_summary(import_log, _stats), do: "Import finished" <> import_name(import_log)

  defp import_name(%{filename: name}) when is_binary(name) and name != "", do: " (#{name})"
  defp import_name(_), do: ""

  defp truncate(text, max) when byte_size(text) > max, do: binary_part(text, 0, max) <> "…"
  defp truncate(text, _max), do: text

  # A notification must never take down the thing it is reporting on.
  defp safely(fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.warning("[Shop] notification failed: #{inspect(error)}")
      :ok
  catch
    kind, value ->
      Logger.warning("[Shop] notification failed: #{inspect(kind)} #{inspect(value)}")
      :ok
  end
end
