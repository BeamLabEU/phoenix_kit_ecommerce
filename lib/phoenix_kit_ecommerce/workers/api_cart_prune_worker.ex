defmodule PhoenixKitEcommerce.Workers.ApiCartPruneWorker do
  @moduledoc """
  Daily deletion of the empty carts the sweep abandoned: `api:`
  carts in status `abandoned`, with no lines, not touched for 30 days. Carts
  that still have lines are kept (an operator may want to see what an
  assistant put in them). Claims of a deleted cart go with it (foreign key).
  Does nothing while the shop module is disabled.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem

  @retention_days 30
  @batch 500

  @impl Oban.Worker
  def perform(_job) do
    if PhoenixKitEcommerce.enabled?() do
      {:ok, count} = prune()
      if count > 0, do: Logger.info("[Shop] deleted #{count} empty abandoned assistant carts")
    end

    :ok
  end

  @doc "Deletes the empty abandoned `api:` carts untouched since 30 days before `now`."
  @spec prune(DateTime.t()) :: {:ok, non_neg_integer()}
  def prune(now \\ UtilsDate.utc_now()) do
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)
    lines = from(i in CartItem, where: i.cart_uuid == parent_as(:cart).uuid, select: 1)

    uuids =
      from(c in Cart,
        as: :cart,
        where: c.status == "abandoned",
        where: like(c.session_id, "api:%"),
        where: c.updated_at < ^cutoff,
        where: not exists(lines),
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
