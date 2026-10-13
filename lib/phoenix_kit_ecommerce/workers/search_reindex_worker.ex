defmodule PhoenixKitEcommerce.Workers.SearchReindexWorker do
  @moduledoc """
  Re-indexes products in the public search index.

  ## Job arguments

    * `"kind" => "item"`, `"uuid"` - one product.
    * `"kind" => "items"`, `"uuids"` - a list of products.
    * `"kind" => "category"`, `"uuid"` - every product in the category and in
      all of its descendants (the category's name or position is part of every
      product's `category_path`).

  Uses the `shop_search` queue (declared by `PhoenixKitEcommerce.oban_queues/0`).
  Enqueue through `PhoenixKitEcommerce.Search.Jobs`, which coalesces bursts.
  """

  use Oban.Worker, queue: :shop_search, max_attempts: 3

  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.Search.Indexer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "item", "uuid" => uuid}}), do: reindex([uuid])

  def perform(%Oban.Job{args: %{"kind" => "items", "uuids" => uuids}}) when is_list(uuids),
    do: reindex(uuids)

  def perform(%Oban.Job{args: %{"kind" => "category", "uuid" => uuid}}) when is_binary(uuid) do
    uuid
    |> Loader.subtree_uuids(Loader.categories())
    |> Loader.item_ids_in_categories()
    |> reindex()
  end

  # Only the argument keys are reported: the values are ids from an event.
  def perform(%Oban.Job{args: args}),
    do: {:cancel, "unknown search job, argument keys: #{inspect(Map.keys(args))}"}

  defp reindex(uuids) do
    {:ok, _stats} = Indexer.reindex_items(uuids)
    :ok
  end
end
