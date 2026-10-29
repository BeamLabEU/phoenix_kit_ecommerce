defmodule PhoenixKitEcommerce.Availability do
  @moduledoc """
  Whether a product can be offered to a shopper right now.

  Today every listed product is available: the storefront has no stock to
  consult (`PhoenixKitEcommerce.StockTracking` only says whether tracking is
  on). This is the one place stock will be read, so the blocks that recommend
  products (`PhoenixKitEcommerce.RelatedProducts`) ask here and a stock
  feature changes this function, not them.

  An application can already supply the answer through
  `config :phoenix_kit_ecommerce, :availability, {Module, :function}`; the
  function takes the product and returns a boolean (only `false` means
  unavailable). A hook that is missing, has the wrong arity, raises, exits
  (a `GenServer.call` timeout, say) or throws counts as available and is
  logged as a warning with the hook and what went wrong, so a broken hook
  never empties or crashes a page and is not silent either.
  """

  require Logger

  @spec available?(term()) :: boolean()
  def available?(product) do
    case Application.get_env(:phoenix_kit_ecommerce, :availability) do
      {module, function} when is_atom(module) and is_atom(function) ->
        ask(module, function, product)

      _ ->
        true
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
