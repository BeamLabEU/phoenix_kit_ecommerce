defmodule PhoenixKitEcommerce.API.DetachImages do
  @moduledoc """
  `ecommerce.detach_images`: takes pictures out of a product's gallery. A
  picture is named by its file `id` or by the `url` it was attached from
  (query stripped, as `ecommerce.attach_images` stores it); exactly one of the
  two. Only a picture the product's gallery names (`data["media_order"]` and
  the featured pointer) can be removed; anything else is reported in
  `not_attached` and changes nothing, so a retry of a call that succeeded is
  `unchanged`, and another product's picture can not be reached by naming it.

  A picture leaves the product by core's removal rule for a folder
  (`ResourceFolders.detach/2`, the one the catalogue's editor uses): a link is
  dropped; a file homed in the product's folder moves to another product's
  folder that also holds it, or is trashed (never hard deleted, the media
  trash can restore it) when nothing else holds it. The gallery order follows,
  and the featured pointer is cleared when the featured picture goes, as the
  editor's remove button does; the storefront then shows the first picture
  left.

  The tool is dangerous when a row would leave its product with no picture at
  all. Removing the featured picture alone is not: replacing a main picture is
  an attach followed by a detach. A batch over `api_confirm_batch_over` rows is
  held by core's executor for every admin write tool. With `ctx.dry_run?` the
  handler returns `{:preview, preview, fingerprint}` and writes nothing.
  """

  @compile {:no_warn_undefined,
            [PhoenixKit.Modules.Storage.ResourceFolders, PhoenixKitCatalogue.Catalogue]}

  require Logger

  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.{Batch, CatalogueWrites, Gate, Meta, PlanSupport, Rows}
  alias PhoenixKitEcommerce.Catalogue.Writer
  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.StorefrontCache

  @tool "ecommerce.detach_images"
  @max_images 50
  @changed_message "A gallery changed while the call was being checked. Read the product again and repeat the call."

  @doc "The most pictures one product may name in a call."
  @spec max_images() :: pos_integer()
  def max_images, do: @max_images

  @doc "Handler of the tool."
  @spec run(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | Gate.refusal()
  def run(input, ctx) do
    with {:ok, catalogue_uuid, rows} <- plan_rows(input) do
      if Map.get(ctx, :dry_run?, false),
        do: preview(rows),
        else: write(rows, ctx, catalogue_uuid)
    end
  end

  defp preview(rows) do
    preview = rows |> Batch.preview() |> Batch.with_confirmation(rows)
    {:preview, preview, Batch.fingerprint(rows)}
  end

  defp write(rows, ctx, catalogue_uuid) do
    with :ok <- Batch.ensure_not_newly_dangerous(rows, ctx, @changed_message) do
      {:ok, rows |> detach(ctx, catalogue_uuid) |> Batch.render()}
    end
  end

  @doc "The `danger` check of the tool: `true` when the call needs a confirmation."
  @spec dangerous?(map(), map()) :: boolean()
  def dangerous?(input, _ctx) do
    case plan_rows(input) do
      {:ok, _catalogue_uuid, rows} -> Batch.dangerous?(rows)
      {:error, _code, _detail, _context} -> false
    end
  end

  # -- planning ---------------------------------------------------------------

  defp plan_rows(input) do
    with {:ok, catalogue_uuid} <- Gate.check(input) do
      shopify? = PhoenixKitEcommerce.shopify_enabled?()
      items = input["items"]
      url_index = url_index(items)

      rows =
        items
        |> Batch.load(catalogue_uuid)
        |> Batch.plan(&plan_row(&1, url_index, shopify?))
        |> Enum.map(&show_split/1)

      {:ok, catalogue_uuid, rows}
    end
  end

  # URL (query stripped) -> file uuid for the URLs of this call.
  defp url_index(items) do
    keys =
      for item <- items,
          %{"url" => url} <- Map.get(item, "images", []),
          key = ImageDownloader.source_key(url),
          uniq: true,
          do: key

    case keys do
      [] -> %{}
      keys -> Writer.build_reuse_index(keys).url_index
    end
  end

  defp plan_row(%{item: item, input: input}, url_index, shopify?) do
    images = Map.get(input, "images", [])

    case wanted(images, url_index) do
      {:ok, wanted} ->
        gallery = gallery(item)
        {remove, _not_attached} = split(wanted, gallery)

        {:ok,
         %{
           from: %{media_order: media_order(item), featured: featured(item)},
           changes: %{"images" => %{"remove" => length(remove)}},
           changed?: remove != [],
           dangerous?: remove != [] and gallery -- remove == [],
           warnings: warnings(item, remove, shopify?),
           wanted: wanted
         }}

      {:error, errors} ->
        {:error, Rows.invalid(errors)}
    end
  end

  # `[{label, file_uuid | nil}]`: what each named picture is called in the
  # answer, and the file it is (none when no stored file came from that URL).
  defp wanted(images, url_index) do
    images
    |> Enum.with_index()
    |> Enum.map(&parse(&1, url_index))
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> case do
      {parsed, []} -> {:ok, for({:ok, one} <- parsed, do: one)}
      {_parsed, errors} -> {:error, for({:error, error} <- errors, do: error)}
    end
  end

  defp parse({%{"id" => id} = image, index}, _url_index)
       when is_binary(id) and map_size(image) == 1 do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, {uuid, uuid}}
      :error -> {:error, PlanSupport.error("images[#{index}].id", "must be a file UUID")}
    end
  end

  defp parse({%{"url" => url} = image, _index}, url_index)
       when is_binary(url) and map_size(image) == 1 do
    key = ImageDownloader.source_key(url)
    {:ok, {key, Map.get(url_index, key)}}
  end

  defp parse({_image, index}, _url_index),
    do: {:error, PlanSupport.error("images[#{index}]", "give exactly one of id or url")}

  # What the gallery lets go of, in the order the call named it, and the
  # names that match no picture of it.
  defp split(wanted, gallery) do
    {held, other} =
      wanted
      |> Enum.uniq()
      |> Enum.split_with(fn {_label, file} -> file in gallery end)

    {Enum.uniq(for({_label, file} <- held, do: file)), for({label, _file} <- other, do: label)}
  end

  defp show_split(%{plan: %{wanted: wanted}, item: item} = row) do
    {remove, not_attached} = split(wanted, gallery(item))
    %{row | extra: %{"detached" => length(remove), "not_attached" => not_attached}}
  end

  defp show_split(row), do: row

  # The Shopify media sync replaces a product's picture order and featured
  # picture, so a picture taken out of a linked product can come back.
  defp warnings(item, remove, shopify?) do
    if remove != [] and PlanSupport.shopify_sync_may_overwrite?(item, shopify?),
      do: ["shopify_sync_may_overwrite"],
      else: []
  end

  # -- detaching --------------------------------------------------------------

  defp detach(rows, ctx, catalogue_uuid) do
    rows =
      Enum.map(rows, fn
        %{plan: %{changed?: true}} = row -> detach_row_safely(row, ctx, catalogue_uuid)
        row -> row
      end)

    if Enum.any?(rows, &match?(%{result: {:ok, _}}, &1)), do: StorefrontCache.clear()
    rows
  end

  # An exception in one row must not take the answers of the rows already
  # committed with it, nor the cache clear: it is that row's storage_error.
  # Only the exception module is logged: its message can hold request values.
  defp detach_row_safely(row, ctx, catalogue_uuid) do
    detach_row(row, ctx, catalogue_uuid)
  rescue
    error -> row |> log_raised(ctx, error.__struct__) |> fail_storage()
  catch
    :exit, _reason -> row |> log_raised(ctx, :exit) |> fail_storage()
  end

  defp log_raised(row, ctx, class) do
    Logger.error(
      "[detach_images] request #{Map.get(ctx, :request_id)}: detaching raised: #{inspect(class)}"
    )

    row
  end

  defp fail_storage(row) do
    Batch.fail(
      row,
      Rows.error(:validation_failed, "The pictures could not be detached.", %{
        "reason" => "storage_error"
      })
    )
  end

  # The product is read again with its row locked: the gallery it has now, and
  # whether it is still in the shop catalogue, are what counts, not what the
  # plan read. The files are released and the gallery written in one
  # transaction, so a gallery that could not be written leaves the files where
  # they were.
  defp detach_row(%{item: item} = row, ctx, catalogue_uuid) do
    locked_result =
      CatalogueWrites.with_locked_items([item], fn locked ->
        case available(locked, item, catalogue_uuid) do
          {:ok, fresh} -> detach_from(%{row | item: fresh}, ctx)
          :error -> gone(row)
        end
      end)

    case locked_result do
      {:ok, detached} -> detached
      {:error, error} -> Batch.fail(row, error)
    end
  end

  defp available(locked, item, catalogue_uuid) do
    with {:ok, fresh} <- Map.fetch(locked, item.uuid),
         true <- Batch.available?(fresh, catalogue_uuid) do
      {:ok, fresh}
    else
      _gone -> :error
    end
  end

  defp gone(row),
    do: Batch.fail(row, Rows.error(:not_found, "The product is no longer in the shop catalogue."))

  defp detach_from(%{item: item, plan: plan} = row, ctx) do
    {remove, not_attached} = split(plan.wanted, gallery(item))
    {released, failed} = release(remove, folder(item))

    extra = %{
      "detached" => length(released),
      "not_attached" => not_attached,
      "failed" => failed
    }

    cond do
      released != [] ->
        write(row, released, extra, ctx)

      failed != [] ->
        Batch.fail(
          row,
          Rows.error(:validation_failed, "No picture could be detached.", %{"images" => failed})
        )

      true ->
        %{row | plan: %{plan | changed?: false}, extra: Map.delete(extra, "failed")}
    end
  end

  # Core's removal rule for each file. A file the folder does not hold (gone,
  # or only named by the gallery) is released all the same: the gallery must
  # stop naming it.
  defp release(files, folder) do
    {released, failed} =
      Enum.reduce(files, {[], []}, fn file, {released, failed} ->
        case ResourceFolders.detach(file, folder) do
          {:ok, _outcome} ->
            {[file | released], failed}

          {:error, reason} ->
            Logger.error("[detach_images] detaching a file failed: " <> Meta.term_class(reason))
            {released, [file | failed]}
        end
      end)

    {Enum.reverse(released), Enum.reverse(failed)}
  end

  defp write(%{item: item, plan: plan} = row, released, extra, ctx) do
    order = media_order(item) -- released

    data = %{"media_order" => order}

    data =
      if featured(item) in released, do: Map.put(data, "featured_image_uuid", nil), else: data

    opts = [
      data_owned_keys: Map.keys(data),
      actor_uuid: Meta.actor_uuid(ctx),
      log_metadata: Meta.log_metadata(ctx, @tool),
      mode: "auto"
    ]

    case Catalogue.update_item(item, %{data: data}, opts) do
      {:ok, updated} ->
        log(updated, ctx, extra)

        %{
          row
          | item: updated,
            result: {:ok, updated},
            plan: %{plan | changes: %{"images" => %{"remove" => length(released)}}},
            extra: extra
        }

      {:error, reason} ->
        Logger.error("[detach_images] saving the gallery failed: " <> Meta.term_class(reason))
        PhoenixKit.Config.get_repo().rollback(:gallery_not_saved)
    end
  end

  # -- the gallery ------------------------------------------------------------

  # The pictures a product names: its featured picture and its order.
  defp gallery(item), do: Enum.uniq(List.wrap(featured(item)) ++ media_order(item))

  defp featured(item) do
    case get_in(item.data || %{}, ["featured_image_uuid"]) do
      uuid when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

  defp media_order(item) do
    case get_in(item.data || %{}, ["media_order"]) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp folder(item) do
    case get_in(item.data || %{}, ["files_folder_uuid"]) do
      uuid when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

  defp log(item, ctx, extra) do
    PhoenixKitEcommerce.Activity.log("shop.api_images_detached",
      actor_uuid: Meta.actor_uuid(ctx),
      mode: "auto",
      resource_type: "product",
      resource_uuid: item.uuid,
      metadata:
        Map.merge(Meta.log_metadata(ctx, @tool), %{
          "detached" => extra["detached"],
          "not_attached" => length(extra["not_attached"]),
          "failed" => length(extra["failed"])
        })
    )
  end
end
