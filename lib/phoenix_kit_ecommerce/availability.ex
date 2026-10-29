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
  function takes the product and returns a boolean. A missing or failing
  function counts as available, so a broken hook never empties a page.
  """

  @spec available?(term()) :: boolean()
  def available?(product) do
    case Application.get_env(:phoenix_kit_ecommerce, :availability) do
      {module, function} when is_atom(module) and is_atom(function) ->
        module |> apply(function, [product]) |> Kernel.!=(false)

      _ ->
        true
    end
  rescue
    _ -> true
  end
end
