defmodule PhoenixKitEcommerce.Shipment do
  @moduledoc """
  A shipment of a paid order registered (or being registered) with a carrier.
  Written and read through `PhoenixKitEcommerce.Shipments`.

  `context_snapshot` holds what the carrier was called with: the method's
  provider settings (with `settings["integration"]` set to `integration_uuid`),
  the connection's `environment`, and the country, currency and locale of the
  order. `parcels`, `recipient` and `destination` are the data sent: copied
  from the order and corrected by the admin before an attempt. `events` keeps
  the last 50 changes and `error` the last failure, both masked.
  `submitted_at` is set when an attempt claims the shipment for the carrier
  call and cleared by a retry: one attempt reaches the carrier once.

  Statuses: `creating` and `unknown` while the outcome is open; the carrier
  states `created`, `in_transit`, `ready_for_pickup`, `delivered` and
  `returned`; `cancelled`; `failed`. An order has at most one shipment in a
  live status (`live_statuses/0`): a partial unique index refuses a second.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @statuses ~w(creating unknown created in_transit ready_for_pickup delivered returned cancelled failed)
  @live_statuses ~w(creating unknown created in_transit ready_for_pickup)

  @typedoc "A shipment row."
  @type t :: %__MODULE__{}

  schema "phoenix_kit_shop_shipments" do
    field :order_uuid, UUIDv7
    field :method_uuid, UUIDv7
    field :integration_uuid, UUIDv7
    field :provider, :string
    field :service, :string
    field :context_snapshot, :map, default: %{}
    field :parcels, {:array, :map}, default: []
    field :recipient, :map, default: %{}
    field :destination, :map, default: %{}
    field :status, :string
    field :tracking_number, :string
    field :tracking_url, :string
    field :carrier_ref, :string
    field :carrier_label, :string
    field :extra, :map, default: %{}
    field :events, {:array, :map}, default: []
    field :error, :string
    field :created_by_uuid, UUIDv7
    field :last_tracked_at, :utc_datetime
    field :submitted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime)
  end

  @doc "Every status a shipment can have."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The statuses of a live shipment; an order has at most one."
  @spec live_statuses() :: [String.t()]
  def live_statuses, do: @live_statuses

  @doc "The name of the partial unique index over the live statuses."
  @spec live_index() :: atom()
  def live_index, do: :idx_shop_shipments_live_order
end
