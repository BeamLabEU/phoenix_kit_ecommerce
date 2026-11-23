defmodule PhoenixKitEcommerce.CartRedenominateRaceTest do
  @moduledoc """
  Two re-denominations of one cart at once, in opposite directions (two tabs on
  two domains): whichever takes the cart row second finds the row already moved
  and decides on what it finds there. The cart ends in one of the two
  currencies, whole and consistent: every line in the cart's currency and priced
  from its base amount at the cart's rate, the totals the sum of the lines, no
  line lost or doubled, and neither call fails or deadlocks.

  The SQL sandbox wraps a test in one transaction, so the callers here run on
  real connections (`unboxed_run`, as `ClaimsRaceTest` does) and the rows are
  committed. `async: false`; the carts and products they create are removed
  afterwards.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Test.Repo

  @moduletag :integration

  @rounds 8

  # The committed currencies of the test database are used as they are (other
  # tests delete and recreate them inside their own sandbox transaction, never
  # for real): the shop's base and two other enabled currencies.
  setup do
    unboxed(fn ->
      PhoenixKit.Cache.clear(:billing_currencies)
      base = Repo.get_by(Currency, is_default: true)

      others =
        Repo.all(from(c in Currency, where: c.enabled and not c.is_default, order_by: c.code))

      if base == nil or length(others) < 2 do
        flunk("the test database needs a base currency and two other enabled currencies")
      end

      [first, second | _] = others
      %{base: base, first: first, second: second}
    end)
  end

  test "opposite re-denominations of one cart leave it whole and in one currency", ctx do
    for _round <- 1..@rounds do
      cart = cart_with_lines!(ctx.first)
      stale = %{cart | currency: ctx.second.code}

      outcomes =
        race([
          fn -> Shop.redenominate_cart(cart, ctx.second.code) end,
          fn -> Shop.redenominate_cart(stale, ctx.first.code) end
        ])

      assert [{:ok, _}, {:ok, _}] = outcomes

      unboxed(fn -> assert_consistent(cart.uuid, ctx) end)
    end
  end

  test "many at once, still one consistent currency", ctx do
    cart = cart_with_lines!(ctx.first)

    outcomes =
      race(
        for target <- [ctx.second, ctx.first, ctx.second, ctx.first, ctx.second, ctx.first] do
          other = if target.code == ctx.first.code, do: ctx.second, else: ctx.first
          stale = %{cart | currency: other.code}
          fn -> Shop.redenominate_cart(stale, target.code) end
        end
      )

    assert Enum.all?(outcomes, &match?({:ok, _}, &1))
    unboxed(fn -> assert_consistent(cart.uuid, ctx) end)
  end

  defp assert_consistent(cart_uuid, ctx) do
    cart = Repo.get!(Cart, cart_uuid)
    lines = Repo.all(from(i in CartItem, where: i.cart_uuid == ^cart_uuid))
    currency = Enum.find([ctx.first, ctx.second], &(&1.code == cart.currency))

    assert currency, "the cart ended in #{cart.currency}"
    assert cart.base_currency == ctx.base.code
    assert length(lines) == 3, "a line was lost or doubled"

    rate = Currency.effective_rate(currency, ctx.base)
    assert Decimal.equal?(cart.exchange_rate, rate)

    for line <- lines do
      assert line.currency == cart.currency
      expected = Currency.present(line.base_unit_price, cart.currency, rate: rate)
      assert Decimal.equal?(line.unit_price, expected), "a line is not priced at the cart's rate"
      assert Decimal.equal?(line.line_total, Decimal.mult(expected, line.quantity))
    end

    subtotal = lines |> Enum.map(& &1.line_total) |> Enum.reduce(&Decimal.add/2)
    assert Decimal.equal?(cart.subtotal, subtotal)
    assert Decimal.equal?(cart.total, subtotal)
  end

  defp cart_with_lines!(currency) do
    session_id = "redenominate-race-#{System.unique_integer([:positive])}"

    unboxed(fn ->
      Currency.put_request_currency(currency.code)
      {:ok, cart} = Shop.create_cart(session_id: session_id)
      assert cart.currency == currency.code

      delete_on_exit(Cart, cart.uuid)

      filled = Enum.reduce(1..3, cart, &add_line!/2)
      Currency.put_request_currency(nil)
      filled
    end)
  end

  # The rows are committed, so the test removes them itself (the cart's lines go
  # with the cart).
  defp delete_on_exit(schema, uuid) do
    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(r in schema, where: r.uuid == ^uuid)) end)
    end)
  end

  defp add_line!(quantity, cart) do
    {:ok, updated} = Shop.add_to_cart(cart, product!(), quantity)
    updated
  end

  defp product! do
    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Race Vase #{n}"},
        "price" => Decimal.new("13#{rem(n, 10)}.35"),
        "status" => "active",
        "product_type" => "digital",
        "requires_shipping" => false,
        "weight_grams" => 0
      })

    delete_on_exit(Product, product.uuid)

    product
  end

  # One task per function, each on its own real connection, held until all are
  # ready and released together. The answers come back in the order of `funs`.
  defp race(funs) do
    parent = self()
    tasks = for fun <- funs, do: Task.async(fn -> wait_then(parent, fun) end)

    for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 30_000)
  end

  defp wait_then(parent, fun) do
    unboxed(fn ->
      send(parent, {:ready, self()})

      receive do
        :go -> fun.()
      end
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
