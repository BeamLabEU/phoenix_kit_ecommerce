defmodule PhoenixKitEcommerce.Test.Shipping.NoCancelProvider do
  @moduledoc """
  The `StubProvider` under another key (`"nocancel"`) and without
  `cancel_shipment/2`: a carrier the shop can register shipments with and
  print labels of, but not cancel them at. Configured the same way as the
  stub (`StubProvider.put/1`).
  """

  @behaviour PhoenixKitEcommerce.Shipping.Provider

  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @impl true
  def key, do: "nocancel"

  @impl true
  def label, do: "Carrier without cancel"

  @impl true
  defdelegate services(ctx), to: StubProvider

  @impl true
  defdelegate settings_fields(), to: StubProvider

  @impl true
  defdelegate quote(request, ctx), to: StubProvider

  @impl true
  defdelegate search_localities(query, ctx), to: StubProvider

  @impl true
  defdelegate list_pickup_points(locality, service, query, ctx), to: StubProvider

  @impl true
  defdelegate create_shipment(request, ctx), to: StubProvider

  @impl true
  defdelegate print_labels(refs, options, ctx), to: StubProvider
end
