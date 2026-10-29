defmodule PhoenixKitEcommerce.CartAddRaceTest do
  @moduledoc """
  An active-cart lookup cannot protect a later add from checkout. Exercise
  both add paths on committed data, with another transaction changing the
  cart while the add waits for its row. The sandbox cannot reproduce that
  race inside a single shared transaction.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Test.Repo

  @moduletag :integration

  setup tags do
    {previous, cart, product} =
      unboxed(fn ->
        previous = Settings.get_setting("shop_enabled", "false")
        Settings.update_setting("shop_enabled", "true")

        {:ok, product} =
          %Product{}
          |> Product.changeset(%{
            title: %{"en" => "Cart add race"},
            price: Decimal.new("5.00"),
            status: "active",
            currency: Shop.get_default_currency_code(),
            requires_shipping: false,
            metadata:
              if(tags[:selected_options],
                do: %{"_option_values" => %{"color" => ["Red", "Blue"]}},
                else: %{}
              )
          })
          |> Repo.insert()

        {:ok, cart} =
          Shop.create_cart(session_id: "add-race-#{System.unique_integer([:positive])}")

        {previous, cart, product}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(c in Cart, where: c.uuid == ^cart.uuid))
        Repo.delete_all(from(p in Product, where: p.uuid == ^product.uuid))
        Settings.update_setting("shop_enabled", previous)
      end)
    end)

    %{cart: cart, product: product}
  end

  for {label, opts} <- [
        {"simple", []},
        {"selected options", [selected_specs: %{"color" => "Red"}]}
      ] do
    @tag selected_options: opts != []
    test "#{label}: a stale cart cannot insert or increment a line after conversion", %{
      cart: cart,
      product: product
    } do
      opts = unquote(Macro.escape(opts))

      unboxed(fn ->
        Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: "converted"])
        assert {:error, :cart_not_active} = Shop.add_to_cart(cart, product, 1, opts)
        assert Shop.get_cart!(cart.uuid).items == []

        Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: "active"])
        assert {:ok, added} = Shop.add_to_cart(cart, product, 1, opts)
        Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: "converted"])

        assert {:error, :cart_not_active} = Shop.add_to_cart(added, product, 1, opts)
        assert [%{quantity: 1}] = Shop.get_cart!(cart.uuid).items
      end)
    end

    @tag selected_options: opts != []
    test "#{label}: an add waiting for checkout refuses the converted cart", %{
      cart: cart,
      product: product
    } do
      holder = hold_conversion(cart)

      adder =
        Task.async(fn ->
          unboxed(fn -> Shop.add_to_cart(cart, product, 1, unquote(Macro.escape(opts))) end)
        end)

      assert Task.yield(adder, 300) == nil, "add did not wait for the cart row"
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 10_000)

      assert {:error, :cart_not_active} = Task.await(adder, 10_000)
      assert %Cart{status: "converted", items: []} = unboxed(fn -> Shop.get_cart!(cart.uuid) end)
    end
  end

  defp hold_conversion(cart) do
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn -> hold_transaction(cart, parent) end)
      end)

    assert_receive :holding, 5_000
    task
  end

  defp hold_transaction(cart, parent),
    do: Repo.transaction(fn -> convert_then_wait(cart, parent) end)

  defp convert_then_wait(cart, parent) do
    Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: "converted"])
    send(parent, :holding)

    receive do
      :release -> :ok
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
