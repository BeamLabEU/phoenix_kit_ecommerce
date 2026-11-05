defmodule PhoenixKitEcommerce.Availability do
  @moduledoc """
  Whether a product can be offered to a shopper right now.

  A product is available unless stock tracking counts it and none is on hand
  (`PhoenixKitEcommerce.StockTracking`). The blocks that recommend products
  (`PhoenixKitEcommerce.RelatedProducts`) ask here, so they stop offering what
  cannot be bought.

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
  def available?(product) do
    case Application.get_env(:phoenix_kit_ecommerce, :availability) do
      {module, function} when is_atom(module) and is_atom(function) ->
        ask(module, function, product)

      _ ->
        in_stock?(StockTracking.item_uuid(product))
    end
  end

  defp in_stock?(nil), do: true

  defp in_stock?(item_uuid) do
    case StockTracking.on_hand([item_uuid]) do
      %{^item_uuid => 0} -> false
      _some_or_off -> true
    end
  end

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
