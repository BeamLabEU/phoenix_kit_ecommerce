defmodule PhoenixKitEcommerce.OrderStockHandlerTest do
  @moduledoc """
  The write-off of a paid order: billing's order event, one real goods issue
  through `phoenix_kit_warehouse`, and the keeper told when stock falls short.
  `async: false`: flips the process-wide `shop_product_source` key.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue
  @moduletag :warehouse

  @compile {:no_warn_undefined, PhoenixKitWarehouse.GoodsIssues}

  import Ecto.Query, only: [from: 2]
  import PhoenixKitEcommerce.SearchFixtures, only: [catalogue_item!: 2, catalogue_source!: 0]
  import PhoenixKitEcommerce.StockFixtures

  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.OrderEvents
  alias PhoenixKitBilling.Workers.OrderEventWorker
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.OrderStockHandler, as: Handler
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.StockTracking
  alias PhoenixKitWarehouse.GoodsIssues

  @action "shop.order_stock_short"

  setup do
    catalogue = catalogue_source!()
    location = track_stock!()

    vase = catalogue_item!(catalogue, "Vase")
    plate = catalogue_item!(catalogue, "Plate")
    put_stock!(vase.uuid, 5)
    put_stock!(plate.uuid, 5)

    %{location: location, vase: vase, plate: plate, user: fixture_user()}
  end

  defp product_line(item, quantity, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "product",
        "name" => item.name,
        "sku" => "SKU",
        "quantity" => quantity,
        "catalogue_item_uuid" => item.uuid,
        "requires_shipping" => true,
        "unit_price" => "10.00",
        "total" => "10.00"
      },
      extra
    )
  end

  defp paid_order(user, lines, metadata \\ %{"source" => "shop_checkout"}) do
    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("10.00"),
        "currency" => "USD",
        "status" => "confirmed",
        "billing_snapshot" => %{"email" => user.email},
        "line_items" => lines,
        "metadata" => metadata
      })

    {:ok, paid} = Billing.mark_order_paid(order)
    paid
  end

  defp issues, do: GoodsIssues.list_goods_issues()

  defp event_job(order) do
    worker = inspect(OrderEventWorker)

    Repo.all(from(j in Oban.Job, where: j.worker == ^worker))
    |> Enum.find(
      &(&1.args["order_uuid"] == order.uuid and &1.args["handler"] == inspect(Handler))
    )
  end

  test "billing finds the handler through the module" do
    assert Handler in OrderEvents.handlers()
  end

  describe "a paid shop order" do
    test "the event billing queued takes the goods out of stock", %{user: user, vase: vase} do
      order = paid_order(user, [product_line(vase, 2)])

      assert :ok = OrderEventWorker.perform(event_job(order))

      assert Decimal.equal?(on_hand(vase.uuid), 3)
    end

    test "is one posted sale that names the order", ctx do
      order = paid_order(ctx.user, [product_line(ctx.vase, 2), product_line(ctx.plate, 1)])

      assert :ok = Handler.handle_order_event(:paid, order)

      assert [issue] = issues()
      assert issue.status == "posted"
      assert issue.reason == "sale"
      assert issue.external_ref == order.order_number
      assert issue.location_uuid == ctx.location
      assert issue.performed_by_uuid == nil
      assert issue.source_refs == [%{"type" => "shop_order", "uuid" => order.uuid}]

      assert [%{"item_uuid" => _, "issued_quantity" => "2"}, %{"issued_quantity" => "1"}] =
               Enum.sort_by(issue.lines, & &1["name"], :desc)
    end

    test "two lines of one item are one line of the issue", %{user: user, vase: vase} do
      lines = [product_line(vase, 2), product_line(vase, 1, %{"selected_specs" => %{"c" => "r"}})]

      assert :ok = Handler.handle_order_event(:paid, paid_order(user, lines))

      assert [%{lines: [%{"issued_quantity" => "3"}]}] = issues()
      assert Decimal.equal?(on_hand(vase.uuid), 2)
    end

    test "a second delivery changes nothing", %{user: user, vase: vase} do
      order = paid_order(user, [product_line(vase, 2)])

      assert :ok = Handler.handle_order_event(:paid, order)
      assert :ok = Handler.handle_order_event(:paid, order)

      assert [_one] = issues()
      assert Decimal.equal?(on_hand(vase.uuid), 3)
    end

    test "leaves out what is not goods", %{user: user, vase: vase, plate: plate} do
      order =
        paid_order(user, [
          product_line(vase, 1),
          product_line(plate, 1, %{"requires_shipping" => false}),
          %{"type" => "product", "name" => "Legacy", "quantity" => 1, "unit_price" => "1.00"},
          %{"type" => "shipping", "name" => "Post", "quantity" => 1, "unit_price" => "1.00"}
        ])

      assert :ok = Handler.handle_order_event(:paid, order)

      assert [%{lines: [%{"name" => "Vase"}]}] = issues()
      assert Decimal.equal?(on_hand(plate.uuid), 5)
    end

    test "a line stored without the shipping flag counts as goods", %{user: user, vase: vase} do
      line = vase |> product_line(1) |> Map.delete("requires_shipping")

      assert :ok = Handler.handle_order_event(:paid, paid_order(user, [line]))

      assert Decimal.equal?(on_hand(vase.uuid), 4)
    end

    test "with no goods posts nothing", %{user: user} do
      line = %{"type" => "product", "name" => "Legacy", "quantity" => 1, "unit_price" => "1.00"}

      assert :ok = Handler.handle_order_event(:paid, paid_order(user, [line]))

      assert issues() == []
    end
  end

  describe "a line the stock does not cover" do
    setup ctx do
      keeper = keeper!()
      put_stock!(ctx.vase.uuid, 1)
      order = paid_order(ctx.user, [product_line(ctx.vase, 2), product_line(ctx.plate, 1)])

      %{keeper: keeper, order: order}
    end

    test "posts nothing, ends the job and tells the keeper", ctx do
      assert :ok = Handler.handle_order_event(:paid, ctx.order)

      assert issues() == []
      assert Decimal.equal?(on_hand(ctx.vase.uuid), 1)
      assert Decimal.equal?(on_hand(ctx.plate.uuid), 5)
      assert Billing.get_order(ctx.order.uuid).status == "paid"

      assert [text | _] = notification_texts_for_action(@action)
      assert text =~ ctx.order.order_number
      assert text =~ "Vase (needs 2, 1 on hand)"
    end

    test "sends the keeper to the goods issues", %{keeper: keeper, order: order} do
      assert :ok = Handler.handle_order_event(:paid, order)

      assert [link] =
               Repo.all(
                 from(n in "phoenix_kit_notifications",
                   where: n.recipient_uuid == type(^keeper.uuid, Ecto.UUID),
                   select: n.metadata
                 )
               )
               |> Enum.map(& &1["notification_link"])

      assert link == Routes.path("/admin/warehouse/goods-issues")
    end

    test "a second delivery tells nobody twice", ctx do
      assert :ok = Handler.handle_order_event(:paid, ctx.order)
      once = count_notifications(@action)
      assert once > 0

      assert :ok = Handler.handle_order_event(:paid, ctx.order)

      assert count_notifications(@action) == once
    end

    test "the mark is no edit of the order", %{order: order} do
      before = Billing.get_order(order.uuid)

      assert :ok = Handler.handle_order_event(:paid, order)

      after_mark = Billing.get_order(order.uuid)
      assert after_mark.metadata["_shop_stock_short"] == true
      assert after_mark.updated_at == before.updated_at
      assert Billing.Order.revision(after_mark) == Billing.Order.revision(before)
    end

    test "stock that arrived before a redelivery is written off", ctx do
      assert :ok = Handler.handle_order_event(:paid, ctx.order)
      put_stock!(ctx.vase.uuid, 2)

      assert :ok = Handler.handle_order_event(:paid, ctx.order)

      assert [%{status: "posted"}] = issues()
      assert Decimal.equal?(on_hand(ctx.vase.uuid), 0)
    end
  end

  describe "nothing is written off" do
    test "for an order the shop did not place", %{user: user, vase: vase} do
      order = paid_order(user, [product_line(vase, 1)], %{})

      assert :ok = Handler.handle_order_event(:paid, order)

      assert issues() == []
    end

    test "while tracking is off", %{user: user, vase: vase} do
      {:ok, false} = StockTracking.set_enabled(false)

      assert :ok = Handler.handle_order_event(:paid, paid_order(user, [product_line(vase, 1)]))

      assert issues() == []
    end

    test "for a :paid that arrives after the refund", %{user: user, vase: vase} do
      order = paid_order(user, [product_line(vase, 1)])
      {:ok, refunded} = Billing.mark_order_refunded(order)

      assert :ok = Handler.handle_order_event(:paid, refunded)

      assert issues() == []
    end

    test "on a refund or a cancellation, which give nothing back yet", ctx do
      order = paid_order(ctx.user, [product_line(ctx.vase, 1)])

      assert :ok = Handler.handle_order_event(:refunded, order)
      assert :ok = Handler.handle_order_event(:cancelled, order)

      assert issues() == []
      assert Decimal.equal?(on_hand(ctx.vase.uuid), 5)
    end
  end

  test "an order placed at the checkout carries what the write-off needs", %{vase: vase} do
    product = CatalogueSource.get_product(vase.uuid, [])
    {:ok, method} = Shop.create_shipping_method(%{"name" => "Post", "price" => Decimal.new("5")})
    {:ok, cart} = Shop.create_cart(session_id: "stock-#{System.unique_integer([:positive])}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 2)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")
    {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

    {:ok, confirmed} = Billing.confirm_order(order)
    {:ok, paid} = Billing.mark_order_paid(confirmed)

    assert :ok = OrderEventWorker.perform(event_job(paid))

    assert [%{external_ref: number, lines: [%{"name" => "Vase"}]}] = issues()
    assert number == order.order_number
    assert Decimal.equal?(on_hand(vase.uuid), 3)
  end

  defp keeper! do
    user = fixture_user()
    role = Roles.get_role_by_name("Admin")
    {:ok, _} = Roles.assign_role(user, "Admin")
    {:ok, _} = Permissions.grant_permission(role.uuid, "shop.manage_carts")
    user
  end
end
