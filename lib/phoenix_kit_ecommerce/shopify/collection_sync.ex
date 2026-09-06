defmodule PhoenixKitEcommerce.Shopify.CollectionSync do
  @moduledoc """
  Maps Shopify collections onto catalogue categories, preserving both
  orders — Block 7 Task 4 (`docs/superpowers/plans/2026-09-06-block7-
  shopify-media-collections.md`, §5 Блок 7 in the design spec).

  `run/1` fetches every collection via `opts[:client]` (a module
  exposing `fetch_collections/1`/`fetch_collection_product_ids/2`,
  defaulting to `PhoenixKitEcommerce.Shopify.AdminClient` — both
  `opts` keyword lists are forwarded to it as-is, so `:integration_uuid`/
  `:req_options` reach the real client the same way they reach
  `AdminClient.fetch_products/2`), resolves each to a catalogue category
  (match by `slug[primary] == handle`, then by `name` case-insensitive,
  else create — Shopify collections are flat, so a created category's
  `parent_uuid` is always `nil`; the existing tree is never touched),
  and writes `category.position` = the collection's own `position`
  (`AdminClient.fetch_collections/1`'s running index across
  `custom_collections` then `smart_collections`, in API order) plus
  `category.data["ecommerce"]["shopify"]["collection_id"]`.

  Then, walking collections in that same order, each collection's
  product ids (`fetch_collection_product_ids/2` — already in the
  collection's own sort order) are matched to catalogue items by
  `data["ecommerce"]["shopify"]["product_id"]`. An item already sitting
  in ANY collection-derived category (its own or another's, from this
  run or a previous one) is left there — a product listed in two
  collections keeps whichever one it was placed in first; only a
  same-category revisit updates `item.position`. An item with no
  collection-derived category yet (nil, or some unrelated/legacy
  category) is assigned to the collection currently being walked, with
  `item.position` = its index in that collection's product list. A
  product id with no matching item is collected into
  `:unmatched_products` instead.

  A no-op — `{:error, :catalogue_source_inactive}` — when
  `ProductSource.current/0` isn't `Catalogue` (Global Constraints: every
  new Block 7 writer is legacy-source-safe on its own).

  `opts[:catalogue_uuid]` is required — unlike `Writer`'s functions,
  which resolve the shop's one catalogue internally, this module takes
  it explicitly so a caller (the Task 5 worker, or a test) controls
  exactly which catalogue is touched.

  Categories with no matching Shopify collection at all (e.g. a
  manually-curated category the store never modeled as a collection)
  are never looked at here, let alone modified.
  """

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.Shopify.AdminClient
  alias PhoenixKitEcommerce.Translations

  @doc """
  See the moduledoc. `opts`:

    * `:client` — module implementing `fetch_collections/1` and
      `fetch_collection_product_ids/2`; defaults to `AdminClient`.
    * `:catalogue_uuid` — required.
    * anything else (`:integration_uuid`, `:req_options`, ...) is
      forwarded to the client calls unchanged.
  """
  @spec run(keyword()) ::
          {:ok,
           %{
             categories_created: non_neg_integer(),
             categories_matched: non_neg_integer(),
             items_assigned: non_neg_integer(),
             items_repositioned: non_neg_integer(),
             unmatched_products: [term()]
           }}
          | {:error, :catalogue_source_inactive | :missing_catalogue_uuid | term()}
  def run(opts \\ []) when is_list(opts) do
    if ProductSource.current() == ProductSource.Catalogue do
      do_run(opts)
    else
      {:error, :catalogue_source_inactive}
    end
  end

  defp do_run(opts) do
    client = Keyword.get(opts, :client, AdminClient)

    with {:ok, catalogue_uuid} <- resolve_catalogue_uuid(Keyword.get(opts, :catalogue_uuid)),
         {:ok, collections} <- client.fetch_collections(opts) do
      {resolved, created, matched} = resolve_categories(collections, catalogue_uuid)
      collection_category_uuids = MapSet.new(resolved, & &1.category_uuid)
      item_index = items_by_product_id(catalogue_uuid)

      case assign_products(resolved, client, opts, item_index, collection_category_uuids) do
        {:ok, _item_index, assigned, repositioned, unmatched} ->
          {:ok,
           %{
             categories_created: created,
             categories_matched: matched,
             items_assigned: assigned,
             items_repositioned: repositioned,
             unmatched_products: Enum.reverse(unmatched)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_catalogue_uuid(uuid) when is_binary(uuid) and uuid != "", do: {:ok, uuid}
  defp resolve_catalogue_uuid(_), do: {:error, :missing_catalogue_uuid}

  # ============================================================
  # Phase 1: collections -> categories, with order
  # ============================================================

  defp resolve_categories(collections, catalogue_uuid) do
    primary = Translations.default_language()
    existing = Catalogue.list_categories_metadata_for_catalogue(catalogue_uuid)

    {resolved, _categories, created, matched} =
      Enum.reduce(collections, {[], existing, 0, 0}, fn collection,
                                                        {resolved, categories, created, matched} ->
        case resolve_one_category(collection, categories, catalogue_uuid, primary) do
          {:matched, category} ->
            entry = %{id: collection["id"], category_uuid: category.uuid}
            {[entry | resolved], replace_category(categories, category), created, matched + 1}

          {:created, category} ->
            entry = %{id: collection["id"], category_uuid: category.uuid}
            {[entry | resolved], [category | categories], created + 1, matched}
        end
      end)

    {Enum.reverse(resolved), created, matched}
  end

  defp resolve_one_category(collection, categories, catalogue_uuid, primary) do
    handle = collection["handle"]
    title = collection["title"] || handle
    position = collection["position"] || 0
    collection_id = to_string(collection["id"])

    case find_category(categories, handle, title, primary) do
      {:ok, category} ->
        {:ok, updated} = update_matched_category(category, position, collection_id)
        {:matched, updated}

      :not_found ->
        {:ok, category} =
          create_matched_category(catalogue_uuid, title, handle, position, collection_id, primary)

        {:created, category}
    end
  end

  defp find_category(categories, handle, title, primary) do
    case Enum.find(categories, &(primary_slug(&1, primary) == handle)) do
      nil -> find_category_by_name(categories, title)
      category -> {:ok, category}
    end
  end

  defp find_category_by_name(categories, title) do
    downcased_title = String.downcase(title || "")

    case Enum.find(categories, &(String.downcase(&1.name || "") == downcased_title)) do
      nil -> :not_found
      category -> {:ok, category}
    end
  end

  defp primary_slug(%{slug: slug}, primary) when is_map(slug), do: slug[primary]
  defp primary_slug(_category, _primary), do: nil

  defp update_matched_category(category, position, collection_id) do
    Catalogue.update_category(category, %{
      position: position,
      data: put_collection_id(category.data, collection_id)
    })
  end

  defp create_matched_category(catalogue_uuid, title, handle, position, collection_id, primary) do
    Catalogue.create_category(%{
      name: title,
      catalogue_uuid: catalogue_uuid,
      parent_uuid: nil,
      position: position,
      slug: %{primary => handle},
      data: put_collection_id(%{}, collection_id)
    })
  end

  defp put_collection_id(data, collection_id) do
    ecommerce = (data || %{})["ecommerce"] || %{}
    shopify = Map.put(ecommerce["shopify"] || %{}, "collection_id", collection_id)
    Map.put(data || %{}, "ecommerce", Map.put(ecommerce, "shopify", shopify))
  end

  defp replace_category(categories, updated) do
    Enum.map(categories, fn category ->
      if category.uuid == updated.uuid, do: updated, else: category
    end)
  end

  # ============================================================
  # Phase 2: collection product lists -> item category/position
  # ============================================================

  defp items_by_product_id(catalogue_uuid) do
    catalogue_uuid
    |> Catalogue.list_items_for_catalogue()
    |> Map.new(&{shopify_product_id(&1), &1})
    |> Map.delete(nil)
  end

  defp shopify_product_id(item) do
    get_in(item.data || %{}, ["ecommerce", "shopify", "product_id"])
  end

  defp assign_products(resolved, client, opts, item_index, collection_category_uuids) do
    Enum.reduce_while(resolved, {:ok, item_index, 0, 0, []}, fn collection, acc ->
      handle_collection(collection, client, opts, collection_category_uuids, acc)
    end)
  end

  defp handle_collection(
         collection,
         client,
         opts,
         collection_category_uuids,
         {:ok, index, assigned, repositioned, unmatched}
       ) do
    with {:ok, product_ids} <- client.fetch_collection_product_ids(collection.id, opts),
         {:ok, _index, _assigned, _repositioned, _unmatched} = ok <-
           assign_collection_products(
             product_ids,
             collection.category_uuid,
             collection_category_uuids,
             index,
             assigned,
             repositioned,
             unmatched
           ) do
      {:cont, ok}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp assign_collection_products(
         product_ids,
         category_uuid,
         collection_category_uuids,
         index,
         assigned,
         repositioned,
         unmatched
       ) do
    product_ids
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, index, assigned, repositioned, unmatched}, fn {product_id,
                                                                              position},
                                                                             {:ok, index,
                                                                              assigned,
                                                                              repositioned,
                                                                              unmatched} ->
      case Map.fetch(index, to_string(product_id)) do
        :error ->
          {:cont, {:ok, index, assigned, repositioned, [product_id | unmatched]}}

        {:ok, item} ->
          reconcile_item(
            item,
            category_uuid,
            position,
            collection_category_uuids,
            index,
            assigned,
            repositioned,
            unmatched
          )
      end
    end)
  end

  defp reconcile_item(
         item,
         category_uuid,
         position,
         collection_category_uuids,
         index,
         assigned,
         repositioned,
         unmatched
       ) do
    cond do
      item.category_uuid == category_uuid ->
        with_reposition(item, position, index, assigned, repositioned, unmatched)

      MapSet.member?(collection_category_uuids, item.category_uuid) ->
        {:cont, {:ok, index, assigned, repositioned, unmatched}}

      true ->
        with_assignment(item, category_uuid, position, index, assigned, repositioned, unmatched)
    end
  end

  defp with_reposition(item, position, index, assigned, repositioned, unmatched) do
    if item.position == position do
      {:cont, {:ok, index, assigned, repositioned, unmatched}}
    else
      case Catalogue.update_item(item, %{position: position}) do
        {:ok, updated} ->
          index = Map.put(index, shopify_product_id(updated), updated)
          {:cont, {:ok, index, assigned, repositioned + 1, unmatched}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end
  end

  defp with_assignment(item, category_uuid, position, index, assigned, repositioned, unmatched) do
    case Catalogue.update_item(item, %{category_uuid: category_uuid, position: position}) do
      {:ok, updated} ->
        index = Map.put(index, shopify_product_id(updated), updated)
        {:cont, {:ok, index, assigned + 1, repositioned + 1, unmatched}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end
end
