defmodule PhoenixKitEcommerce.API.PlanSupport do
  @moduledoc """
  The few helpers the row planners and `ecommerce.get_prices` share: the
  `data["ecommerce"]` namespace of an item, a conditional map put, and the
  error map of a planned row.
  """

  @doc "The `data[\"ecommerce\"]` map of an item; `%{}` when there is none."
  @spec ecommerce(map()) :: map()
  def ecommerce(item) do
    case item.data do
      %{"ecommerce" => %{} = ecommerce} -> ecommerce
      _ -> %{}
    end
  end

  @doc "`Map.put/3` when `condition` is true, else the map unchanged."
  @spec put_if(map(), boolean(), term(), term()) :: map()
  def put_if(map, true, key, value), do: Map.put(map, key, value)
  def put_if(map, false, _key, _value), do: map

  @doc "The error of one field of a row; `allowed` names the accepted values, if any."
  @spec error(String.t(), String.t(), [String.t()] | nil) :: %{
          path: String.t(),
          message: String.t(),
          allowed: [String.t()] | nil
        }
  def error(path, message, allowed \\ nil), do: %{path: path, message: message, allowed: allowed}
end
