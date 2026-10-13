defmodule PhoenixKitEcommerce.Search.SubscriberTest do
  @moduledoc """
  Messages in, Oban jobs out. The subscriber runs for the length of one test
  (`start_supervised!/1`); `:sys.get_state/1` is the barrier that makes sure
  it has handled a message before the jobs are read.

  `async: false`: the subscriber listens to global PubSub topics and works in
  the shared sandbox connection.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.PubSub}

  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.Search.Subscriber
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    pid = start_supervised!({Subscriber, name: :search_subscriber_test, boot_check_ms: nil})
    # The first message the process handles is its own :subscribe; wait for it.
    _ = :sys.get_state(pid)
    %{pid: pid}
  end

  defp deliver(pid, message) do
    send(pid, message)
    _ = :sys.get_state(pid)
    :ok
  end

  defp jobs do
    from(j in Oban.Job, order_by: [asc: j.id], select: {j.worker, j.args})
    |> Repo.all()
    |> Enum.map(fn {worker, args} -> {worker |> String.split(".") |> List.last(), args} end)
  end

  defp item_job(uuid), do: {"SearchReindexWorker", %{"kind" => "item", "uuid" => uuid}}

  test "a product update enqueues one reindex job", %{pid: pid} do
    uuid = Ecto.UUID.generate()

    deliver(pid, {:product_updated, %{uuid: uuid}})
    deliver(pid, {:product_updated, %{uuid: uuid}})

    assert jobs() == [item_job(uuid)]
  end

  test "product created, deleted and bulk status events", %{pid: pid} do
    [a, b, c, d] = for _ <- 1..4, do: Ecto.UUID.generate()

    deliver(pid, {:product_created, %{uuid: a}})
    deliver(pid, {:product_deleted, b})
    deliver(pid, {:products_bulk_status_changed, [c, d], "archived"})

    assert jobs() == [
             item_job(a),
             item_job(b),
             {"SearchReindexWorker", %{"kind" => "items", "uuids" => [c, d]}}
           ]
  end

  test "category events enqueue a subtree job; bulk category events a rebuild", %{pid: pid} do
    [a, b] = for _ <- 1..2, do: Ecto.UUID.generate()

    deliver(pid, {:category_updated, %{uuid: a}})
    deliver(pid, {:category_deleted, b})
    deliver(pid, {:categories_bulk_parent_changed, [a, b], nil})
    deliver(pid, {:categories_bulk_status_changed, [a], "hidden"})

    assert jobs() == [
             {"SearchReindexWorker", %{"kind" => "category", "uuid" => a}},
             {"SearchReindexWorker", %{"kind" => "category", "uuid" => b}},
             {"SearchRebuildWorker", %{}}
           ]
  end

  test "a catalogue item event enqueues that item; one without an id rebuilds", %{pid: pid} do
    item = Ecto.UUID.generate()
    catalogue = Ecto.UUID.generate()

    deliver(pid, {:catalogue_data_changed, :item, item, catalogue})
    deliver(pid, {:catalogue_data_changed, :item, nil, catalogue})

    assert jobs() == [
             item_job(item),
             {"SearchRebuildWorker", %{"catalogue_uuid" => catalogue}}
           ]
  end

  test "catalogue category events, rebuild kinds, and kinds the index does not care about", %{
    pid: pid
  } do
    category = Ecto.UUID.generate()
    catalogue = Ecto.UUID.generate()

    deliver(pid, {:catalogue_data_changed, :category, category, catalogue})
    deliver(pid, {:catalogue_data_changed, :attribute_set, Ecto.UUID.generate(), catalogue})
    deliver(pid, {:catalogue_data_changed, :manufacturer, Ecto.UUID.generate(), nil})
    deliver(pid, {:catalogue_data_changed, :supplier, Ecto.UUID.generate(), nil})
    deliver(pid, {:catalogue_data_changed, :pdf, Ecto.UUID.generate(), catalogue})

    assert jobs() == [
             {"SearchReindexWorker", %{"kind" => "category", "uuid" => category}},
             {"SearchRebuildWorker", %{"catalogue_uuid" => catalogue}}
           ]
  end

  test "a catalogue bulk change with ids reindexes them, any kind; without ids it rebuilds", %{
    pid: pid
  } do
    catalogue = Ecto.UUID.generate()
    [a, b] = for _ <- 1..2, do: Ecto.UUID.generate()

    deliver(pid, {:catalogue_bulk_change, catalogue, :trashed, [a], self()})
    deliver(pid, {:catalogue_bulk_change, catalogue, :some_future_kind, [b], self()})
    deliver(pid, {:catalogue_bulk_change, catalogue, :moved, nil, self()})

    assert jobs() == [
             {"SearchReindexWorker", %{"kind" => "items", "uuids" => [a]}},
             {"SearchReindexWorker", %{"kind" => "items", "uuids" => [b]}},
             {"SearchRebuildWorker", %{"catalogue_uuid" => catalogue}}
           ]

    other = Ecto.UUID.generate()
    deliver(pid, {:catalogue_bulk_change, other, :restored, [], self()})

    assert List.last(jobs()) == {"SearchRebuildWorker", %{"catalogue_uuid" => other}}
    assert length(jobs()) == 4
  end

  test "nothing is enqueued while the shop module is disabled", %{pid: pid} do
    {:ok, _} = Settings.update_setting("shop_enabled", "false")

    deliver(pid, {:product_updated, %{uuid: Ecto.UUID.generate()}})
    deliver(pid, {:catalogue_data_changed, :item, Ecto.UUID.generate(), nil})

    assert jobs() == []
  end

  test "messages it does not know are ignored and the process keeps running", %{pid: pid} do
    ref = Process.monitor(pid)

    deliver(pid, :unexpected)
    deliver(pid, {:catalogue_card_refresh, 1, 2, 3, 4, self()})
    deliver(pid, {:product_updated, :not_a_product})

    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    assert jobs() == []
  end

  test "events broadcast through Events reach the subscriber", %{pid: pid} do
    uuid = Ecto.UUID.generate()

    Events.broadcast_product_updated(%{uuid: uuid})
    _ = :sys.get_state(pid)

    assert jobs() == [item_job(uuid)]
  end

  @tag :catalogue
  test "events broadcast on the catalogue topic reach the subscriber", %{pid: pid} do
    uuid = Ecto.UUID.generate()
    catalogue = Ecto.UUID.generate()

    CataloguePubSub.broadcast(:item, uuid, catalogue)
    _ = :sys.get_state(pid)

    assert jobs() == [item_job(uuid)]
  end

  test "the boot check enqueues a rebuild when the index is empty", %{pid: pid} do
    deliver(pid, :boot_check)

    assert jobs() == [{"SearchRebuildWorker", %{}}]
  end

  test "the boot check leaves a filled index alone", %{pid: pid} do
    Repo.query!(
      """
      INSERT INTO phoenix_kit_shop_search_index (item_uuid, language, title, title_trgm, document)
      VALUES ($1, 'en', 'A', 'a', to_tsvector('simple', 'a'))
      """,
      [Ecto.UUID.bingenerate()]
    )

    deliver(pid, :boot_check)

    assert jobs() == []
  end
end
