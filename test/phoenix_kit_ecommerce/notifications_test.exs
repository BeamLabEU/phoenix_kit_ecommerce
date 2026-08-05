defmodule PhoenixKitEcommerce.NotificationsTest do
  @moduledoc """
  Who hears about an order or an import, and the two contracts that keep
  the audit trail and the notification layer from doubling up.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce.Notifications, as: ShopNotifications

  describe "notification_types/0" do
    test "declares separate admin and customer sub-types" do
      [%{key: "shop", sub_types: subs}] = PhoenixKitEcommerce.notification_types()

      keys = Enum.map(subs, & &1.key)
      assert "orders" in keys
      assert "order_confirmations" in keys
      assert "imports" in keys

      # Separate sub-types are the point: a shop operator muting the order
      # firehose must not also silence their own receipts.
      orders = Enum.find(subs, &(&1.key == "orders"))
      confirmations = Enum.find(subs, &(&1.key == "order_confirmations"))

      assert orders.actions == ["shop.order_placed"]
      assert confirmations.actions == ["shop.order_confirmed"]
    end

    test "every action belongs to exactly one sub-type" do
      [%{sub_types: subs}] = PhoenixKitEcommerce.notification_types()

      all = Enum.flat_map(subs, & &1.actions)
      assert all == Enum.uniq(all)
    end

    test "the audit action is NOT registered as a notification action" do
      # core's Activity.log/1 auto-derives notifications from registered
      # actions, so an audit row written with a notify action would deliver
      # a duplicate on top of the explicit fan-out.
      [%{sub_types: subs}] = PhoenixKitEcommerce.notification_types()
      registered = Enum.flat_map(subs, & &1.actions)

      refute "shop.order_converted" in registered
      refute "shop.import_run_completed" in registered
      refute "shop.import_run_failed" in registered
    end
  end

  describe "recipient resolution" do
    test "returns a unique list and never raises" do
      recipients = ShopNotifications.admin_recipients("shop.manage_carts")

      assert is_list(recipients)
      assert recipients == Enum.uniq(recipients)
      assert Enum.all?(recipients, &is_binary/1)
    end
  end

  describe "sends are best-effort" do
    test "order_placed/1 tolerates a malformed order rather than raising" do
      # The caller is the checkout path, AFTER the money is committed: a
      # notification must never be able to undo a placed order.
      assert :ok = ShopNotifications.order_placed(%{})
    end

    test "import notifications no-op for logs without an initiator" do
      # Import logs predate the user_uuid column; there is nobody to tell.
      assert :ok = ShopNotifications.import_completed(%{user_uuid: nil}, %{created: 1})
      assert :ok = ShopNotifications.import_failed(%{user_uuid: nil}, :boom)
    end
  end
end
