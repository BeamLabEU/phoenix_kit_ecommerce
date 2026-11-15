defmodule PhoenixKitEcommerce.Availability do
  @moduledoc """
  Whether a product can be offered to a shopper right now.

  A product is available unless stock tracking counts it and none is on hand
  (`PhoenixKitEcommerce.StockTracking`). The blocks that recommend products
  (`PhoenixKitEcommerce.RelatedProducts`) ask here, so they stop offering what
  cannot be bought, and the product page asks `offer/1`, which also says when
  only a few are left.

  An application can supply the answer instead, stock included, through
  `config :phoenix_kit_ecommerce, :availability, {Module, :function}`; the
  function takes the product and returns a boolean (only `false` means
  unavailable). A hook that is missing, has the wrong arity, raises, exits
  (a `GenServer.call` timeout, say) or throws counts as available and is
  logged as a warning with the hook and what went wrong, so a broken hook
  never empties or crashes a page and is not silent either.
  """

  require Logger

  alias PhoenixKitEcommerce.StockTracking

  @spec available?(term()) :: boolean()
  def available?(product), do: offer(product) != :sold_out

  @doc """
  What the product page offers: `:available`, `{:few_left, count}` when stock
  tracking counts the product and at most `StockTracking.low_stock_threshold/0`
  are on hand, or `:sold_out` when none are. An application's hook answers
  instead (`false` is `:sold_out`, anything else `:available`); it says nothing
  about how many are left.
  """
  @spec offer(term()) :: :available | {:few_left, pos_integer()} | :sold_out
  def offer(product) do
    case Application.get_env(:phoenix_kit_ecommerce, :availability) do
      {module, function} when is_atom(module) and is_atom(function) ->
        if ask(module, function, product), do: :available, else: :sold_out

      _ ->
        stock_offer(StockTracking.item_uuid(product))
    end
  end

  defp stock_offer(nil), do: :available

  defp stock_offer(item_uuid) do
    case StockTracking.on_hand([item_uuid]) do
      %{^item_uuid => 0} -> :sold_out
      %{^item_uuid => count} -> few_left(count, StockTracking.low_stock_threshold())
      :off -> :available
    end
  end

  defp few_left(count, threshold) when count <= threshold, do: {:few_left, count}
  defp few_left(_count, _threshold), do: :available

  defp ask(module, function, product) do
    module |> apply(function, [product]) |> Kernel.!=(false)
  catch
    kind, reason ->
      Logger.warning(
        "[Shop] availability hook #{inspect({module, function})} failed " <>
          "(#{inspect(kind)}: #{inspect(reason)}); treating the product as available"
      )

      true
  end
end
