defmodule PhoenixKitEcommerce.Workers.ShipmentTrackingWorker do
  @moduledoc """
  The shipments' half-hourly run (`PhoenixKitEcommerce.oban_crons/0`): moves the
  shipments stuck in `creating` for 10 minutes to `unknown`
  (`Shipments.sweep_stuck/0`), then asks the carriers how the open ones are
  doing (`Shipments.track_shipments/1`).

  On `default`, like the shop's other crons: it is short and must not wait
  behind an import. One attempt: the next run asks again, and a carrier that
  failed is asked again then. Does nothing while the shop module is disabled.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias PhoenixKitEcommerce.Shipments

  @impl Oban.Worker
  def perform(_job) do
    if PhoenixKitEcommerce.enabled?() do
      swept = Shipments.sweep_stuck()
      %{groups: groups, failed: failed, updated: updated} = Shipments.track_shipments()

      if swept > 0 or failed > 0 or updated > 0 do
        Logger.info(
          "[Shop] shipments: #{swept} stuck moved to unknown, #{updated} updated, " <>
            "#{failed} of #{groups} carrier groups failed"
        )
      end
    end

    :ok
  end
end
