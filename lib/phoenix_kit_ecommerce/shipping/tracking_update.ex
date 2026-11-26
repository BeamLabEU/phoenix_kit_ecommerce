defmodule PhoenixKitEcommerce.Shipping.TrackingUpdate do
  @moduledoc """
  One state of a shipment reported by `track/2`.

    * `tracking_number` - which shipment of the request it is about
    * `status` - the shipment status it maps to: `:created`, `:in_transit`,
      `:ready_for_pickup`, `:delivered`, `:returned` or `:cancelled`
    * `occurred_at` - when the carrier says it happened, or `nil`
    * `description` - the carrier's own text, as it gave it (the shop masks
      it before storing)
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  @statuses [:created, :in_transit, :ready_for_pickup, :delivered, :returned, :cancelled]

  defstruct tracking_number: nil, status: nil, occurred_at: nil, description: nil

  @type status :: :created | :in_transit | :ready_for_pickup | :delivered | :returned | :cancelled

  @type t :: %__MODULE__{
          tracking_number: String.t() | nil,
          status: status() | nil,
          occurred_at: DateTime.t() | nil,
          description: String.t() | nil
        }

  @doc "The statuses an update may report."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Serialises the update into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = update), do: Codec.encode(update)

  @doc "Builds an update from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = update), do: update

  def from_map(map) when is_map(map) do
    %__MODULE__{
      tracking_number: map |> Codec.get(:tracking_number) |> Codec.string(),
      status: map |> Codec.get(:status) |> Codec.atom(@statuses),
      occurred_at: map |> Codec.get(:occurred_at) |> Codec.datetime(),
      description: map |> Codec.get(:description) |> Codec.string()
    }
  end

  def from_map(_other), do: nil
end
