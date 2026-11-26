defmodule PhoenixKitEcommerce.Shipping.ShipmentRef do
  @moduledoc """
  A shipment the carrier already has, as the shop stored it: what
  `cancel_shipment/2`, `print_labels/3` and `track/2` are given.

    * `carrier_ref` / `tracking_number` - from the carrier's `ShipmentResult`
    * `service` - the service key it was registered for
    * `extra` - the `ShipmentResult.extra` the adapter returned
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  defstruct carrier_ref: nil, tracking_number: nil, service: nil, extra: %{}

  @type t :: %__MODULE__{
          carrier_ref: String.t() | nil,
          tracking_number: String.t() | nil,
          service: String.t() | nil,
          extra: map()
        }

  @doc "Serialises the reference into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ref), do: Codec.encode(ref)

  @doc "Builds a reference from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = ref), do: ref

  def from_map(map) when is_map(map) do
    %__MODULE__{
      carrier_ref: map |> Codec.get(:carrier_ref) |> Codec.string(),
      tracking_number: map |> Codec.get(:tracking_number) |> Codec.string(),
      service: map |> Codec.get(:service) |> Codec.string(),
      extra: map |> Codec.get(:extra) |> Codec.string_map()
    }
  end

  def from_map(_other), do: nil
end
