defmodule PhoenixKitEcommerce.Search.Subscriber do
  @moduledoc """
  Keeps the public search index fresh: listens to catalogue and e-commerce
  PubSub events and turns them into Oban jobs (`PhoenixKitEcommerce.Search.Jobs`).

  It does no indexing itself, so a crash here can never block a write, and it
  never raises on a message it does not understand. Started by
  `PhoenixKitEcommerce.children/0`.

  Two PubSub servers are involved: the catalogue broadcasts on the host's
  (`PhoenixKit.PubSubHelper`), e-commerce's `Events` on core's internal one.
  A subscription that fails (a server that is not up yet) is retried every
  five seconds; a subscription that succeeded is never repeated.

  While the shop module is disabled events are ignored. Thirty seconds after
  boot `:boot_check` warns once if `pg_trgm` is missing and enqueues a rebuild
  if the index is empty.
  """

  use GenServer

  require Logger

  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Search.Jobs
  alias PhoenixKitEcommerce.Search.Trigram

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.PubSub}

  # Catalogue events that change what the index holds for many products at once.
  @rebuild_kinds [:catalogue, :attribute_set, :attribute_group]
  @boot_check_ms 30_000
  @retry_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    send(self(), :subscribe)

    case Keyword.get(opts, :boot_check_ms, @boot_check_ms) do
      ms when is_integer(ms) -> Process.send_after(self(), :boot_check, ms)
      _none -> :ok
    end

    {:ok, %{subscribed: MapSet.new()}}
  end

  # --- subscriptions ---------------------------------------------------------

  @impl GenServer
  def handle_info(:subscribe, state), do: {:noreply, subscribe_all(state)}

  # --- catalogue events ------------------------------------------------------

  def handle_info({:catalogue_data_changed, :item, uuid, _catalogue}, state)
      when is_binary(uuid) do
    react(fn -> Jobs.enqueue_item(uuid) end)
    {:noreply, state}
  end

  def handle_info({:catalogue_data_changed, :category, uuid, _catalogue}, state)
      when is_binary(uuid) do
    react(fn -> Jobs.enqueue_category(uuid) end)
    {:noreply, state}
  end

  def handle_info({:catalogue_data_changed, kind, nil, catalogue}, state)
      when kind in [:item, :category] do
    react(fn -> Jobs.enqueue_rebuild(catalogue) end)
    {:noreply, state}
  end

  def handle_info({:catalogue_data_changed, kind, _uuid, catalogue}, state)
      when kind in @rebuild_kinds do
    react(fn -> Jobs.enqueue_rebuild(catalogue) end)
    {:noreply, state}
  end

  def handle_info({:catalogue_bulk_change, _catalogue, _kind, [_ | _] = uuids, _from}, state) do
    react(fn -> Jobs.enqueue_items(uuids) end)
    {:noreply, state}
  end

  def handle_info({:catalogue_bulk_change, catalogue, _kind, _no_ids, _from}, state) do
    react(fn -> Jobs.enqueue_rebuild(catalogue) end)
    {:noreply, state}
  end

  # --- e-commerce events (legacy products and categories) --------------------

  def handle_info({event, %{uuid: uuid}}, state)
      when event in [:product_created, :product_updated] and is_binary(uuid) do
    react(fn -> Jobs.enqueue_item(uuid) end)
    {:noreply, state}
  end

  def handle_info({:product_deleted, uuid}, state) when is_binary(uuid) do
    react(fn -> Jobs.enqueue_item(uuid) end)
    {:noreply, state}
  end

  def handle_info({:products_bulk_status_changed, uuids, _status}, state) when is_list(uuids) do
    react(fn -> Jobs.enqueue_items(uuids) end)
    {:noreply, state}
  end

  def handle_info({event, %{uuid: uuid}}, state)
      when event in [:category_created, :category_updated] and is_binary(uuid) do
    react(fn -> Jobs.enqueue_category(uuid) end)
    {:noreply, state}
  end

  def handle_info({:category_deleted, uuid}, state) when is_binary(uuid) do
    react(fn -> Jobs.enqueue_category(uuid) end)
    {:noreply, state}
  end

  def handle_info({event, _ids, _arg}, state)
      when event in [:categories_bulk_status_changed, :categories_bulk_parent_changed] do
    react(fn -> Jobs.enqueue_rebuild(nil) end)
    {:noreply, state}
  end

  def handle_info({:categories_bulk_deleted, _ids}, state) do
    react(fn -> Jobs.enqueue_rebuild(nil) end)
    {:noreply, state}
  end

  # --- boot check ------------------------------------------------------------

  def handle_info(:boot_check, state) do
    react(&boot_check/0)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- internals -------------------------------------------------------------

  defp react(fun) do
    if shop_enabled?(), do: fun.()
    :ok
  end

  defp shop_enabled?, do: PhoenixKitEcommerce.enabled?()

  defp boot_check do
    unless Trigram.available?() do
      Logger.warning("[Search] pg_trgm is not installed: search works, the typo fallback is off")
    end

    if Indexer.empty?(), do: Jobs.enqueue_rebuild(nil)
  rescue
    error -> Logger.warning("[Search] boot check failed: #{inspect(error.__struct__)}")
  end

  defp subscribe_all(state) do
    pending =
      [
        {:catalogue, &subscribe_catalogue/0},
        {:products, &Events.subscribe_products/0},
        {:categories, &Events.subscribe_categories/0}
      ]
      |> Enum.reject(fn {name, _fun} -> MapSet.member?(state.subscribed, name) end)

    subscribed =
      for {name, fun} <- pending, safe_subscribe(name, fun) == :ok, into: state.subscribed do
        name
      end

    if MapSet.size(subscribed) < 3, do: Process.send_after(self(), :subscribe, @retry_ms)

    %{state | subscribed: subscribed}
  end

  defp subscribe_catalogue do
    if Code.ensure_loaded?(CataloguePubSub) do
      CataloguePubSub.subscribe()
    else
      :ok
    end
  end

  defp safe_subscribe(name, fun) do
    case fun.() do
      :ok ->
        :ok

      other ->
        Logger.warning("[Search] could not subscribe to #{name} events: #{inspect(other)}")
        :error
    end
  rescue
    error ->
      Logger.warning(
        "[Search] could not subscribe to #{name} events: #{inspect(error.__struct__)}"
      )

      :error
  catch
    :exit, reason ->
      Logger.warning("[Search] could not subscribe to #{name} events: #{inspect(reason)}")
      :error
  end
end
