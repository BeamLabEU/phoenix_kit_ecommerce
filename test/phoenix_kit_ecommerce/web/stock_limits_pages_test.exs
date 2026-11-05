defmodule PhoenixKitEcommerce.Web.StockLimitsPagesTest do
  @moduledoc """
  What a shopper reads when stock refuses a quantity, on the product page, the
  cart and the checkout. `async: false`: flips the process-wide
  `shop_product_source` key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue
  @moduletag :warehouse

  import PhoenixKitEcommerce.SearchFixtures, only: [catalogue_item!: 3, catalogue_source!: 0]
  import PhoenixKitEcommerce.StockFixtures

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.DataCase
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource

  @slug "stock-limited-vase"

  setup %{conn: conn} do
    track_stock!()

    item =
      catalogue_item!(catalogue_source!(), "Vase", %{
        slug: %{"en-US" => @slug},
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

    put_stock!(item.uuid, 2)

    %{conn: conn, item: item, product: CatalogueSource.get_product(item.uuid, [])}
  end

  defp session_conn(conn) do
    session_id = "stock-pages-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id}), cart}
  end

  test "the product page says how many are left", %{conn: conn, item: item} do
    {conn, cart} = session_conn(conn)
    {:ok, _cart} = Shop.add_to_cart(cart, CatalogueSource.get_product(item.uuid, []), 2)

    {:ok, view, _html} = live(conn, "/shop/product/#{@slug}")
    html = view |> element("button[phx-click=add_to_cart]") |> render_click()

    assert html =~ "Insufficient stock (only 2 available)"
    assert [%{quantity: 2}] = Shop.get_cart(cart.uuid).items
  end

  test "the product page says when it is gone", %{conn: conn, item: item} do
    {conn, cart} = session_conn(conn)
    put_stock!(item.uuid, 0)

    {:ok, view, _html} = live(conn, "/shop/product/#{@slug}")
    html = view |> element("button[phx-click=add_to_cart]") |> render_click()

    assert html =~ "This item is out of stock"
    assert [] = Shop.get_cart(cart.uuid).items
  end

  test "the cart refuses a quantity above the stock", %{conn: conn, product: product} do
    {conn, cart} = session_conn(conn)
    {:ok, %{items: [line]}} = Shop.add_to_cart(cart, product, 1)

    {:ok, view, _html} = live(conn, "/cart")

    html =
      view
      |> element("#cart-quantity-form-#{line.uuid}")
      |> render_change(%{"item_uuid" => line.uuid, "quantity" => "3"})

    assert html =~ "Insufficient stock (only 2 available)"
    assert [%{quantity: 1}] = Shop.get_cart(cart.uuid).items
  end

  test "a checkout the stock no longer covers goes back to the cart", ctx do
    user = DataCase.fixture_user()
    {:ok, method} = Shop.create_shipping_method(%{"name" => "Post", "price" => Decimal.new("5")})
    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, cart} = Shop.add_to_cart(cart, ctx.product, 2)
    {:ok, _cart} = Shop.set_cart_shipping(cart, method, "US")

    for option <- Billing.list_payment_options() do
      {:ok, _} = Billing.update_payment_option(option, %{"active" => option.code == "cod"})
    end

    {:ok, _} =
      "cod"
      |> Billing.get_payment_option_by_code()
      |> Billing.update_payment_option(%{"requires_billing_profile" => false})

    conn = put_test_scope(ctx.conn, fake_scope(user_uuid: user.uuid, email: user.email))
    {:ok, view, _html} = live(conn, "/checkout")

    put_stock!(ctx.item.uuid, 1)
    view |> element("#checkout-confirm-order") |> render_click()

    {path, flash} = assert_redirect(view)
    assert path =~ "/cart"
    assert flash["error"] =~ "Not enough stock for: Vase"
    assert %{status: "active"} = Shop.get_cart(cart.uuid)
  end
end
