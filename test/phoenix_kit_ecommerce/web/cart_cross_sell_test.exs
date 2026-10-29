defmodule PhoenixKitEcommerce.Web.CartCrossSellTest do
  @moduledoc """
  The "Add to your order" block of the cart: what it offers, what it leaves
  out, and the Add button.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.RelatedProducts
  alias PhoenixKitEcommerce.Test.Repo

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

  # The settings cache is ETS-backed and survives a test; start from the defaults
  # whatever an earlier test left behind.
  setup do
    for {key, value} <- [{"shop_related_limit", "4"}, {"shop_related_fallback", "off"}] do
      PhoenixKit.Settings.update_setting(key, value)
    end

    :ok
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

  describe "products with something to choose" do
    @size %{
      "key" => "size",
      "label" => "Size",
      "type" => "select",
      "options" => ["S", "L"],
      "required" => true,
      "affects_price" => true,
      "modifier_type" => "fixed",
      "price_modifiers" => %{"S" => "0", "L" => "5"}
    }

    test "a product whose category has a required option gets a link, not an Add button", ctx do
      {:ok, category} =
        Shop.create_category(%{
          "name" => %{"en" => "Sized"},
          "slug" => %{"en" => "sized-#{System.unique_integer([:positive])}"},
          "option_schema" => [@size]
        })

      sized = product!("Sized vase", %{"category_uuid" => category.uuid})
      shirt = product!("T-shirt") |> cross_sells([sized.uuid])
      cart = put_in_cart(ctx.cart, shirt)

      {:ok, view, _html} = live(ctx.conn, "/cart")

      assert has_element?(view, "#cross-sell-#{sized.uuid} a")
      refute has_element?(view, "#cross-sell-#{sized.uuid} button")

      # Pushed at the page anyway, the event is ignored.
      render_hook(view, "add_cross_sell", %{"uuid" => sized.uuid})
      assert length(Shop.get_cart!(cart.uuid).items) == 1
    end

    test "Add refreshes options introduced after the offer was rendered", ctx do
      {:ok, category} =
        Shop.create_category(%{
          "name" => %{"en" => "Changing options"},
          "slug" => %{"en" => "changing-options-#{System.unique_integer([:positive])}"}
        })

      extra = product!("Changing extra", %{"category_uuid" => category.uuid})
      shirt = product!("T-shirt") |> cross_sells([extra.uuid])
      cart = put_in_cart(ctx.cart, shirt)
      {:ok, view, _html} = live(ctx.conn, "/cart")
      assert has_element?(view, "#cross-sell-#{extra.uuid} button")

      # Optional choices are valid when omitted at the context layer, but
      # the cross-sell must let the buyer choose before adding the product.
      {:ok, _} =
        Shop.update_category(category, %{"option_schema" => [Map.put(@size, "required", false)]})

      render_hook(view, "add_cross_sell", %{"uuid" => extra.uuid})

      assert length(Shop.get_cart!(cart.uuid).items) == 1
      assert has_element?(view, "#cross-sell-#{extra.uuid} a")
      refute has_element?(view, "#cross-sell-#{extra.uuid} button")
    end
  end

  test "Add drops a product whose category became hidden after rendering", ctx do
    {:ok, category} =
      Shop.create_category(%{
        "name" => %{"en" => "Visible shelf"},
        "slug" => %{"en" => "visible-shelf-#{System.unique_integer([:positive])}"}
      })

    extra = product!("Hidden extra", %{"category_uuid" => category.uuid})
    shirt = product!("T-shirt") |> cross_sells([extra.uuid])
    cart = put_in_cart(ctx.cart, shirt)
    {:ok, view, _html} = live(ctx.conn, "/cart")
    assert has_element?(view, "#cross-sell-#{extra.uuid} button")

    {:ok, _} = Shop.update_category(category, %{"status" => "hidden"})
    render_hook(view, "add_cross_sell", %{"uuid" => extra.uuid})

    assert length(Shop.get_cart!(cart.uuid).items) == 1
    refute has_element?(view, "#cross-sell-#{extra.uuid}")
  end

  test "Add drops an offer removed by the merchant after rendering", ctx do
    extra = product!("Removed offer")
    shirt = product!("T-shirt") |> cross_sells([extra.uuid])
    cart = put_in_cart(ctx.cart, shirt)
    {:ok, view, _html} = live(ctx.conn, "/cart")
    assert has_element?(view, "#cross-sell-#{extra.uuid} button")

    cross_sells(shirt, [])
    render_hook(view, "add_cross_sell", %{"uuid" => extra.uuid})

    assert length(Shop.get_cart!(cart.uuid).items) == 1
    refute has_element?(view, "#cross-sell-#{extra.uuid}")
  end

  test "Add ignores a deleted product without crashing the page", ctx do
    extra = product!("Deleted extra")
    shirt = product!("T-shirt") |> cross_sells([extra.uuid])
    cart = put_in_cart(ctx.cart, shirt)
    {:ok, view, _html} = live(ctx.conn, "/cart")
    assert has_element?(view, "#cross-sell-#{extra.uuid} button")

    {:ok, _} = Shop.delete_product(extra)
    render_hook(view, "add_cross_sell", %{"uuid" => extra.uuid})

    assert length(Shop.get_cart!(cart.uuid).items) == 1
    refute has_element?(view, "#cross-sell-#{extra.uuid}")
  end

  test "Add goes into the shopper's active cart, not into one that became an order", ctx do
    calendar = product!("Wall calendar")
    shirt = product!("T-shirt") |> cross_sells([calendar.uuid])
    cart = put_in_cart(ctx.cart, shirt)

    {:ok, view, _html} = live(ctx.conn, "/cart")

    # The cart is converted elsewhere (another tab, the checkout) after the page opened.
    cart |> Ecto.Changeset.change(status: "converted") |> Repo.update!()

    view |> element("#cross-sell-#{calendar.uuid} button") |> render_click()

    assert length(Shop.get_cart!(cart.uuid).items) == 1
    active = Shop.find_active_cart(session_id: cart.session_id)
    assert active.uuid != cart.uuid
    assert calendar.uuid in Enum.map(active.items, & &1.product_uuid)
  end

  test "the block size setting limits the offers", ctx do
    extras = for t <- ~w(A B C), do: product!("Limit #{t}")
    shirt = product!("T-shirt") |> cross_sells(Enum.map(extras, & &1.uuid))
    put_in_cart(ctx.cart, shirt)

    previous = PhoenixKit.Settings.get_setting("shop_related_limit", "")
    PhoenixKit.Settings.update_setting("shop_related_limit", "2")
    on_exit(fn -> PhoenixKit.Settings.update_setting("shop_related_limit", previous) end)

    {:ok, _view, html} = live(ctx.conn, "/cart")

    assert length(Regex.scan(~r/id="cross-sell-[0-9a-f-]{36}"/, html)) == 2
  end

  defmodule Hook do
    @moduledoc false
    def available?(%{title: %{"en" => "Sold out extra"}}), do: false
    def available?(_product), do: true
  end

  test "the availability hook removes a product from the offers", ctx do
    gone = product!("Sold out extra")
    kept = product!("Kept extra")
    shirt = product!("T-shirt") |> cross_sells([gone.uuid, kept.uuid])
    put_in_cart(ctx.cart, shirt)

    Application.put_env(:phoenix_kit_ecommerce, :availability, {Hook, :available?})
    on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :availability) end)

    {:ok, view, _html} = live(ctx.conn, "/cart")

    assert has_element?(view, "#cross-sell-#{kept.uuid}")
    refute has_element?(view, "#cross-sell-#{gone.uuid}")
  end

  test "Add rechecks availability after the offer was rendered", ctx do
    extra = product!("Sold out extra")
    shirt = product!("T-shirt") |> cross_sells([extra.uuid])
    cart = put_in_cart(ctx.cart, shirt)
    {:ok, view, _html} = live(ctx.conn, "/cart")
    assert has_element?(view, "#cross-sell-#{extra.uuid} button")

    Application.put_env(:phoenix_kit_ecommerce, :availability, {Hook, :available?})
    on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :availability) end)
    render_hook(view, "add_cross_sell", %{"uuid" => extra.uuid})

    assert length(Shop.get_cart!(cart.uuid).items) == 1
    refute has_element?(view, "#cross-sell-#{extra.uuid}")
  end
end
