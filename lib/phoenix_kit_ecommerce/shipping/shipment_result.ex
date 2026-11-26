defmodule PhoenixKitEcommerce.Shipping.ShipmentResult do
  @moduledoc """
  What the carrier answered to `create_shipment/2`.

    * `carrier_ref` - the carrier's own id of the shipment, if it has one
    * `tracking_number` - what the recipient tracks the parcel by
    * `tracking_url` - the carrier's tracking page for it, or `nil`
    * `carrier_label` - the carrier that really carries the parcel when the
      provider is an aggregator (Montonio sends through Omniva, say), else `nil`
    * `extra` - provider-private data needed later (labels, cancellation), and
      the sender the adapter used; JSON-safe, values are strings after a
      round trip

  An answer needs a `carrier_ref` or a `tracking_number`; one without either
  is refused by the facade as `{:bad_return, _}`.
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  defstruct carrier_ref: nil,
            tracking_number: nil,
            tracking_url: nil,
            carrier_label: nil,
            extra: %{}

  @type t :: %__MODULE__{
          carrier_ref: String.t() | nil,
          tracking_number: String.t() | nil,
          tracking_url: String.t() | nil,
          carrier_label: String.t() | nil,
          extra: map()
        }

  @doc "Serialises the result into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result), do: Codec.encode(result)

  @doc "Builds a result from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = result), do: result

  def from_map(map) when is_map(map) do
    %__MODULE__{
      carrier_ref: map |> Codec.get(:carrier_ref) |> Codec.string(),
      tracking_number: map |> Codec.get(:tracking_number) |> Codec.string(),
      tracking_url: map |> Codec.get(:tracking_url) |> Codec.string(),
      carrier_label: map |> Codec.get(:carrier_label) |> Codec.string(),
      extra: map |> Codec.get(:extra) |> Codec.string_map()
    }
  end

  def from_map(_other), do: nil
end
