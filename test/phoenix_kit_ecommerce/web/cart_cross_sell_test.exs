defmodule PhoenixKitEcommerce.Web.CartCrossSellTest do
  @moduledoc """
  The "Add to your order" block of the cart: what it offers, what it leaves
  out, and the Add button.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.RelatedProducts

  defp product!(title, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{"en" => title},
            "price" => Decimal.new("4.00"),
            "status" => "active",
            "currency" => "USD",
            "requires_shipping" => false
          },
          attrs
        )
      )

    _ = n
    product
  end

  defp cross_sells(product, ids) do
    {:ok, product} =
      Shop.update_product(product, %{
        "metadata" => %{RelatedProducts.metadata_key(:cross_sell) => ids}
      })

    product
  end

  setup %{conn: conn} do
    session_id = "xsell-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    %{conn: Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id}), cart: cart}
  end

  defp put_in_cart(cart, product) do
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    cart
  end

  test "offers the cross-sells of what is in the cart, with an Add button", ctx do
    calendar = product!("Wall calendar")
    shirt = product!("T-shirt") |> cross_sells([calendar.uuid])
    put_in_cart(ctx.cart, shirt)

    {:ok, view, html} = live(ctx.conn, "/cart")

    assert has_element?(view, "#cart-cross-sells")
    assert html =~ "Add to your order"
    assert has_element?(view, "#cross-sell-#{calendar.uuid} button[phx-click='add_cross_sell']")
  end

  test "Add puts the product in the cart and the offer goes away", ctx do
    calendar = product!("Wall calendar")
    shirt = product!("T-shirt") |> cross_sells([calendar.uuid])
    cart = put_in_cart(ctx.cart, shirt)

    {:ok, view, _html} = live(ctx.conn, "/cart")
    view |> element("#cross-sell-#{calendar.uuid} button") |> render_click()

    uuids = Shop.get_cart!(cart.uuid).items |> Enum.map(& &1.product_uuid)
    assert calendar.uuid in uuids
    refute has_element?(view, "#cross-sell-#{calendar.uuid}")
  end

  test "leaves out what is already in the cart and drafts", ctx do
    in_cart = product!("Already here")
    draft = product!("Secret draft", %{"status" => "draft"})
    offered = product!("Offered one")
    shirt = product!("T-shirt") |> cross_sells([in_cart.uuid, draft.uuid, offered.uuid])
    cart = put_in_cart(ctx.cart, shirt)
    put_in_cart(cart, in_cart)

    {:ok, view, html} = live(ctx.conn, "/cart")

    assert has_element?(view, "#cross-sell-#{offered.uuid}")
    refute has_element?(view, "#cross-sell-#{in_cart.uuid}")
    refute html =~ "Secret draft"
  end

  test "joins the lists of several products once, in cart order, up to the limit", ctx do
    [a, b, c, d, e] = for t <- ~w(A B C D E), do: product!("Extra #{t}")
    one = product!("One") |> cross_sells([a.uuid, b.uuid])
    two = product!("Two") |> cross_sells([b.uuid, c.uuid, d.uuid, e.uuid])
    cart = put_in_cart(ctx.cart, one)
    put_in_cart(cart, two)

    {:ok, view, _html} = live(ctx.conn, "/cart")

    offered =
      view
      |> render()
      |> then(&Regex.scan(~r/id="cross-sell-([0-9a-f-]{36})"/, &1))
      |> Enum.map(fn [_, uuid] -> uuid end)

    assert offered == [a.uuid, b.uuid, c.uuid, d.uuid]
  end

  test "a cart with no cross-sells shows no block", ctx do
    put_in_cart(ctx.cart, product!("Plain"))

    {:ok, view, html} = live(ctx.conn, "/cart")

    refute has_element?(view, "#cart-cross-sells")
    refute html =~ "Add to your order"
  end

  test "Add for a product the block does not offer is ignored", ctx do
    other = product!("Not offered")
    cart = put_in_cart(ctx.cart, product!("Plain"))

    {:ok, view, _html} = live(ctx.conn, "/cart")
    render_hook(view, "add_cross_sell", %{"uuid" => other.uuid})
    render_hook(view, "add_cross_sell", %{"uuid" => 5})
    render_hook(view, "add_cross_sell", %{})

    assert length(Shop.get_cart!(cart.uuid).items) == 1
  end
end
