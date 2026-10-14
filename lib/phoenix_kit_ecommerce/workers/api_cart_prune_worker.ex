defmodule PhoenixKitEcommerce.Workers.ApiCartPruneWorker do
  @moduledoc """
  Daily deletion of the carts the sweep abandoned: `api:` carts in status
  `abandoned`, with or without lines, not touched for 30 days. Anyone can
  create such carts without signing in, so they must not pile up for good;
  they hold no address, e-mail or payment data. Lines and claims of a deleted
  cart go with it (foreign keys). Does nothing while the shop module is
  disabled.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitEcommerce.Cart

  @retention_days 30
  @batch 500

  @impl Oban.Worker
  def perform(_job) do
    if PhoenixKitEcommerce.enabled?() do
      {:ok, count} = prune()
      if count > 0, do: Logger.info("[Shop] deleted #{count} abandoned assistant carts")
    end

    :ok
  end

  @doc "Deletes the abandoned `api:` carts untouched since 30 days before `now`."
  @spec prune(DateTime.t()) :: {:ok, non_neg_integer()}
  def prune(now \\ UtilsDate.utc_now()) do
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)

    uuids =
      from(c in Cart,
        where: c.status == "abandoned",
        where: like(c.session_id, "api:%"),
        where: c.updated_at < ^cutoff,
        select: c.uuid
      )
      |> RepoHelper.repo().all()

    count =
      uuids
      |> Enum.chunk_every(@batch)
      |> Enum.map(fn batch ->
        {deleted, _} = from(c in Cart, where: c.uuid in ^batch) |> RepoHelper.repo().delete_all()
        deleted
      end)
      |> Enum.sum()

    {:ok, count}
  end
end
