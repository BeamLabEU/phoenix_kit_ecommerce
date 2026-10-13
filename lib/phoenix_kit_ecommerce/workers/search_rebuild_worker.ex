defmodule PhoenixKitEcommerce.Workers.SearchRebuildWorker do
  @moduledoc """
  Rebuilds the whole public search index. It is the nightly safety net (the
  cron entry comes from `PhoenixKitEcommerce.oban_crons/0`) and the answer to
  "everything may have changed" events (a bulk write with no ids).

  ## Job arguments

    * none - rebuild.
    * `"catalogue_uuid"` - rebuild only if this is the shop's own catalogue;
      an event about another catalogue of the same install is ignored.

  A rebuild that cannot resolve the shop's catalogue is cancelled, not retried,
  and changes nothing (`PhoenixKitEcommerce.Search.Indexer.rebuild/0`). Two
  rebuild requests with the same arguments inside two minutes are one job.
  """

  use Oban.Worker,
    queue: :shop_search,
    max_attempts: 2,
    unique: [period: 120, states: [:available, :scheduled]]

  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.Search.Indexer

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if wanted?(args) do
      case Indexer.rebuild() do
        {:ok, _stats} -> :ok
        {:error, :no_catalogue} -> {:cancel, "the shop catalogue cannot be resolved"}
      end
    else
      :ok
    end
  end

  defp wanted?(%{"catalogue_uuid" => uuid}) when is_binary(uuid),
    do: uuid == Loader.shop_catalogue_uuid()

  defp wanted?(_args), do: true
end
