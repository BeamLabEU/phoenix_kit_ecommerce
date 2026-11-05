defmodule PhoenixKitEcommerce.API.CartStockTest do
  @moduledoc """
  The public cart API while stock tracking is in force: a line above the stock
  is that line's error and the others go on, and the checkout claim's merge skips
  and names what no longer fits. `async: false`: flips the process-wide
  `shop_product_source` key.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :requires_core_api
  @moduletag :catalogue
  @moduletag :warehouse

  import PhoenixKitEcommerce.CartApiFixtures
  import PhoenixKitEcommerce.SearchFixtures, only: [catalogue_item!: 2, catalogue_source!: 0]
  import PhoenixKitEcommerce.StockFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.API.Loader

  setup do
    put_secret!()
    ensure_currencies!()
    catalogue = catalogue_source!()
    track_stock!()

    vase = catalogue_item!(catalogue, "Vase")
    plate = catalogue_item!(catalogue, "Plate")
    put_stock!(vase.uuid, 3)
    put_stock!(plate.uuid, 3)

    token = new_token!()
    {:ok, hash} = CartToken.verify(token)

    %{vase: vase, plate: plate, token: token, hash: hash}
  end

  defp set(ctx, lines) do
    items =
      for {item, quantity} <- lines, do: %{"product_id" => item.uuid, "quantity" => quantity}

    {:ok, answer} = CartWriter.set_items(ctx.hash, %{"items" => items}, ctx_for(ctx.token))
    answer
  end

  defp by_id(answer), do: Map.new(answer.results, &{&1[:id] || &1.ref, &1})

  test "a new line above the stock is its own error and the others go on", ctx do
    answer = set(ctx, [{ctx.vase, 4}, {ctx.plate, 2}])

    assert [
             %{action: "error", error: %{code: "insufficient_stock", allowed: %{max: 3}}},
             %{action: "created", quantity: 2}
           ] = answer.results

    {:ok, cart} = CartStore.resolve(ctx.hash)
    assert [%{product_title: "Plate", quantity: 2}] = cart.items
  end

  test "a line raised above the stock keeps its quantity", ctx do
    set(ctx, [{ctx.vase, 2}])

    assert %{results: [%{action: "error", error: %{code: "insufficient_stock"}}]} =
             set(ctx, [{ctx.vase, 4}])

    {:ok, cart} = CartStore.resolve(ctx.hash)
    assert [%{quantity: 2}] = cart.items
  end

  test "a line left above the stock can come down", ctx do
    set(ctx, [{ctx.vase, 3}])
    put_stock!(ctx.vase.uuid, 1)

    assert %{results: [%{action: "updated", quantity: 2}]} = set(ctx, [{ctx.vase, 2}])
  end

  test "the claim's merge skips what no longer fits and keeps the rest", ctx do
    set(ctx, [{ctx.vase, 2}, {ctx.plate, 1}])
    {:ok, api_cart} = CartStore.resolve(ctx.hash)
    {:ok, %{token: raw}} = Claims.issue(api_cart, ctx.hash, "en-US")

    session_id = "browser-#{System.unique_integer([:positive])}"
    {:ok, mine} = Shop.create_cart(session_id: session_id)
    vase = Loader.load([ctx.vase.uuid], language: "en-US")[ctx.vase.uuid].product
    {:ok, mine} = Shop.add_to_cart(mine, vase, 2)

    assert {:ok, %{mode: :merged, skipped: ["Vase"]}} =
             redeem_shown(raw, %{session_id: session_id}, %{offer: mine.uuid, choice: "add"})

    lines = Shop.get_cart(mine.uuid).items |> Map.new(&{&1.product_title, &1.quantity})
    assert lines == %{"Vase" => 2, "Plate" => 1}
  end
end
