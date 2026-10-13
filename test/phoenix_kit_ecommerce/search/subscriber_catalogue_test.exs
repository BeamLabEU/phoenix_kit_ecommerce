defmodule PhoenixKitEcommerce.Search.SubscriberCatalogueTest do
  @moduledoc """
  The subscriber against REAL catalogue writes, not fabricated messages: if the
  catalogue changes what it broadcasts, these tests fail.

  `async: false`: the subscriber listens to global PubSub topics, the shop's
  catalogue is found by name across the database.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.Search.Subscriber
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    pid =
      start_supervised!({Subscriber, name: :search_subscriber_catalogue_test, boot_check_ms: nil})

    # The first message the process handles is its own :subscribe; wait for it.
    _ = :sys.get_state(pid)
    %{pid: pid}
  end

  # The writes of the fixtures broadcast too; start counting after them.
  defp clear_jobs(pid) do
    _ = :sys.get_state(pid)
    Repo.delete_all(Oban.Job)
  end

  defp jobs(pid) do
    _ = :sys.get_state(pid)

    from(j in Oban.Job, order_by: [asc: j.id], select: {j.worker, j.args})
    |> Repo.all()
    |> Enum.map(fn {worker, args} -> {worker |> String.split(".") |> List.last(), args} end)
  end

  test "a real item update enqueues a reindex job for that item", %{pid: pid} do
    catalogue = catalogue_source!()
    item = catalogue_item!(catalogue, "Red Vase")
    clear_jobs(pid)

    {:ok, _} = Catalogue.update_item(item, %{name: "Blue Vase"})

    assert {"SearchReindexWorker", %{"kind" => "item", "uuid" => item.uuid}} in jobs(pid)
  end

  test "a real trash and restore of an item each enqueue a job that names it", %{pid: pid} do
    catalogue = catalogue_source!()
    item = catalogue_item!(catalogue, "Red Vase")
    clear_jobs(pid)

    {:ok, trashed} = Catalogue.trash_item(item)
    assert named_or_rebuild?(jobs(pid), item.uuid)

    clear_jobs(pid)
    {:ok, _} = Catalogue.restore_item(trashed)
    assert named_or_rebuild?(jobs(pid), item.uuid)
  end

  test "a real bulk trash of items enqueues a job that covers them", %{pid: pid} do
    catalogue = catalogue_source!()
    a = catalogue_item!(catalogue, "Alpha Vase")
    b = catalogue_item!(catalogue, "Beta Vase")
    clear_jobs(pid)

    assert {2, nil} = Catalogue.bulk_trash_items([a.uuid, b.uuid], [])

    jobs = jobs(pid)
    assert jobs != []
    assert named_or_rebuild?(jobs, a.uuid)
    assert named_or_rebuild?(jobs, b.uuid)
  end

  test "a real category rename enqueues a reindex of the category subtree", %{pid: pid} do
    catalogue = catalogue_source!()
    category = catalogue_category!(catalogue, "Home")
    clear_jobs(pid)

    {:ok, _} = Catalogue.update_category(category, %{name: "Shop"})

    assert {"SearchReindexWorker", %{"kind" => "category", "uuid" => category.uuid}} in jobs(pid)
  end

  # A job covers an item when it names it (a single or a batch job) or when it
  # is a full rebuild.
  defp named_or_rebuild?(jobs, uuid) do
    Enum.any?(jobs, fn
      {"SearchReindexWorker", %{"kind" => "item", "uuid" => ^uuid}} -> true
      {"SearchReindexWorker", %{"kind" => "items", "uuids" => uuids}} -> uuid in uuids
      {"SearchRebuildWorker", _args} -> true
      _other -> false
    end)
  end
end
