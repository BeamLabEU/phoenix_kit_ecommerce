defmodule PhoenixKitEcommerce.API.DetachImagesTest do
  @moduledoc """
  `ecommerce.detach_images` against a real catalogue: pictures leave the
  product's gallery (by file id or by the URL they were attached from), the
  featured pointer follows, a retry changes nothing, a dry run writes nothing
  and says whether the real call would be held, and another product's picture
  is never touched.

  The first block works on gallery entries alone (a picture the gallery names
  whose file is gone is still removed from the list). The second attaches
  real pictures through `ecommerce.attach_images` (HTTP through `Req.Test`,
  pictures drawn with ImageMagick, skipped where it is missing) to see what
  happens to the stored file. `async: false`: it reads the shop-wide URL index.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api
  @moduletag :core_confirm

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.API.DetachImages
  alias PhoenixKitEcommerce.APICase
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.StorefrontCache

  @one "0192a7c0-0000-7000-8000-00000000000a"
  @two "0192a7c0-0000-7000-8000-00000000000b"
  @three "0192a7c0-0000-7000-8000-00000000000c"

  setup do
    catalogue = F.shop_catalogue!()
    user = F.user!()
    %{catalogue: catalogue, user: user, ctx: F.ctx(user)}
  end

  defp detach(rows, ctx), do: APICase.call("ecommerce.detach_images", %{"items" => rows}, ctx)
  defp dry(ctx), do: %{ctx | dry_run?: true}

  # What core's executor sets once a dangerous call was confirmed.
  defp confirmed(ctx), do: Map.put(ctx, :confirmation_uuid, Ecto.UUID.generate())

  defp row(item, images), do: %{"ref" => %{"id" => item.uuid}, "images" => images}
  defp ids(uuids), do: Enum.map(uuids, &%{"id" => &1})

  defp item_with(catalogue, order, featured \\ nil) do
    data =
      %{"_primary_language" => "en", "ecommerce" => %{"shop_status" => "active"}}
      |> Map.put("media_order", order)
      |> then(&if(featured, do: Map.put(&1, "featured_image_uuid", featured), else: &1))

    F.item!(catalogue, %{data: data})
  end

  describe "the gallery" do
    test "takes the named pictures out and keeps the order of the others", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two, @three], @one)

      assert {:ok, %{"results" => [result], "summary" => %{"updated" => 1}}} =
               detach([row(item, ids([@two]))], ctx)

      assert result["action"] == "updated"
      assert result["detached"] == 1
      assert result["not_attached"] == []
      assert result["changes"] == %{"images" => %{"remove" => 1}}

      data = F.reload!(item).data
      assert data["media_order"] == [@one, @three]
      assert data["featured_image_uuid"] == @one
    end

    test "removing the featured picture clears the pointer, as the editor's remove button does",
         %{catalogue: catalogue, ctx: ctx} do
      item = item_with(catalogue, [@one, @two], @one)

      assert {:ok, %{"summary" => %{"updated" => 1}}} = detach([row(item, ids([@one]))], ctx)

      data = F.reload!(item).data
      assert data["media_order"] == [@two]
      refute Map.has_key?(data, "featured_image_uuid")
    end

    test "a featured pointer that is not in the order is a picture of the gallery too", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@two], @one)

      assert {:ok, %{"summary" => %{"updated" => 1}}} = detach([row(item, ids([@one]))], ctx)

      data = F.reload!(item).data
      assert data["media_order"] == [@two]
      refute Map.has_key?(data, "featured_image_uuid")
    end

    test "a picture the product does not have is reported and changes nothing", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      mine = item_with(catalogue, [@one])
      other = item_with(catalogue, [@two])

      assert {:ok, %{"results" => [result], "summary" => %{"unchanged" => 1}}} =
               detach([row(mine, ids([@two]))], ctx)

      assert result["action"] == "unchanged"
      assert result["detached"] == 0
      assert result["not_attached"] == [@two]

      assert F.reload!(mine).data["media_order"] == [@one]
      assert F.reload!(other).data["media_order"] == [@two]
    end

    test "the same call again is unchanged: the retry of a call that succeeded", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two], @one)
      rows = [row(item, ids([@two]))]

      assert {:ok, %{"summary" => %{"updated" => 1}}} = detach(rows, ctx)

      assert {:ok, %{"results" => [again], "summary" => %{"unchanged" => 1}}} =
               detach(rows, ctx)

      assert again["detached"] == 0
      assert F.reload!(item).data["media_order"] == [@one]
    end

    test "a call that empties a gallery without a confirmation is not written", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one])

      assert {:error, :validation_failed, _message, %{errors: [%{path: "items"}]}} =
               detach([row(item, ids([@one]))], ctx)

      assert F.reload!(item).data["media_order"] == [@one]

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               detach([row(item, ids([@one]))], confirmed(ctx))

      assert F.reload!(item).data["media_order"] == []
    end

    test "a picture asked for twice is removed once", %{catalogue: catalogue, ctx: ctx} do
      item = item_with(catalogue, [@one, @two])

      assert {:ok, %{"results" => [result]}} =
               detach([row(item, ids([@one, String.upcase(@one)]))], ctx)

      assert result["detached"] == 1
      assert F.reload!(item).data["media_order"] == [@two]
    end

    test "a row that fails does not stop the others", %{catalogue: catalogue, ctx: ctx} do
      item = item_with(catalogue, [@one])

      rows = [
        %{"ref" => %{"sku" => "NO-SUCH-SKU"}, "images" => ids([@one])},
        row(item, ids([@one]))
      ]

      assert {:ok, %{"results" => [missing, done], "summary" => summary}} =
               detach(rows, confirmed(ctx))

      assert missing["error"]["code"] == "not_found"
      assert done["action"] == "updated"
      assert summary == %{"updated" => 1, "unchanged" => 0, "error" => 1}
    end

    test "refuses a picture given by both id and url, or by neither, on its own row", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one])

      for image <- [%{"id" => @one, "url" => "https://93.184.216.34/a.png"}, %{}] do
        assert {:ok, %{"results" => [result]}} = detach([row(item, [image])], ctx)
        assert result["error"]["code"] == "validation_failed"
        assert inspect(result["error"]) =~ "images[0]"
        assert F.reload!(item).data["media_order"] == [@one]
      end
    end

    test "logs the removal with the API metadata", %{catalogue: catalogue, user: user, ctx: ctx} do
      item = item_with(catalogue, [@one, @two])

      assert {:ok, _} = detach([row(item, ids([@one]))], ctx)

      entry =
        assert_activity_logged("shop.api_images_detached",
          resource_uuid: item.uuid,
          actor_uuid: user.uuid,
          metadata_has: %{"via" => "api", "tool" => "ecommerce.detach_images", "detached" => 1}
        )

      assert entry.mode == "auto"
    end
  end

  describe "the Shopify warning" do
    test "only for a linked product, only while the sync is on", %{catalogue: catalogue, ctx: ctx} do
      shopify = PhoenixKitEcommerce.shopify_enabled?()

      on_exit(fn ->
        Settings.update_boolean_setting_with_module("shop_shopify_enabled", shopify, "shop")
      end)

      linked =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{"shop_status" => "active", "shopify" => %{"product_id" => "7"}},
            "media_order" => [@one, @two]
          }
        })

      plain = item_with(catalogue, [@one, @two])
      rows = [row(linked, ids([@one])), row(plain, ids([@one]))]

      Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")
      assert {:preview, on, _} = detach(rows, dry(ctx))
      assert [%{"warnings" => ["shopify_sync_may_overwrite"]}, %{"warnings" => []}] = on["rows"]

      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      assert {:preview, off, _} = detach(rows, dry(ctx))
      assert [%{"warnings" => []}, %{"warnings" => []}] = off["rows"]
    end
  end

  describe "the storefront cache" do
    setup do
      start_supervised!(PhoenixKit.Cache.Registry)
      [spec] = StorefrontCache.children()
      start_supervised!(spec)
      :ok
    end

    test "a write clears it; a dry run and an unchanged row leave it", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one])

      :stale = StorefrontCache.fetch(:probe, fn -> :stale end)
      assert {:preview, _, _} = detach([row(item, ids([@one]))], dry(ctx))
      assert {:ok, _} = detach([row(item, ids([@two]))], ctx)
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale

      assert {:ok, _} = detach([row(item, ids([@one]))], confirmed(ctx))
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh
    end
  end

  describe "dry run" do
    test "previews the removal, writes nothing and logs nothing", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two])

      assert {:preview, preview, fingerprint} = detach([row(item, ids([@one]))], dry(ctx))

      assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      assert preview["totals"]["update"] == 1

      assert [%{"action" => "update", "changes" => %{"images" => %{"remove" => 1}}}] =
               preview["rows"]

      assert F.reload!(item).data["media_order"] == [@one, @two]
      refute_activity_logged("shop.api_images_detached", resource_uuid: item.uuid)
    end

    test "says the real call is held only when it would leave a product with no pictures", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two], @one)

      requires = fn images ->
        {:preview, preview, _} = detach([row(item, ids(images))], dry(ctx))
        preview["requires_confirmation"]
      end

      refute requires.([@two])
      # the featured picture alone is replaced all the time: not held
      refute requires.([@one])
      assert requires.([@one, @two])
      # nothing to remove is nothing to hold
      refute requires.([@three])
    end

    test "carries core's row threshold among the rules", %{catalogue: catalogue, ctx: ctx} do
      item = item_with(catalogue, [@one])

      assert {:preview, preview, _} = detach([row(item, ids([@two]))], dry(ctx))
      assert preview["confirmation_rules"] == %{"confirm_batch_over" => 50}
    end

    test "agrees with the danger check of the tool", %{catalogue: catalogue, ctx: ctx} do
      item = item_with(catalogue, [@one, @two])

      for images <- [[@one], [@one, @two], [@three]] do
        rows = [row(item, ids(images))]
        input = %{"items" => rows}

        assert {:preview, preview, _} = detach(rows, dry(ctx))
        assert preview["requires_confirmation"] == DetachImages.dangerous?(input, ctx)
      end
    end

    test "a batch over core's row threshold is held whatever it removes", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      previous = Settings.get_setting("api_confirm_batch_over")
      {:ok, _} = Settings.update_setting("api_confirm_batch_over", "2")
      on_exit(fn -> Settings.update_setting("api_confirm_batch_over", previous || "50") end)

      rows = for _ <- 1..3, do: row(item_with(catalogue, [@one, @two]), ids([@one]))

      assert {:preview, preview, _} = detach(rows, dry(ctx))
      assert preview["requires_confirmation"] == true
    end
  end

  describe "real pictures" do
    @describetag skip:
                   if(System.find_executable("convert"),
                     do: false,
                     else: "ImageMagick (convert) is not installed"
                   )

    @stub __MODULE__
    @host "https://93.184.216.34"

    setup %{catalogue: catalogue} do
      dir = Path.join(System.tmp_dir!(), "detach_images_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      Application.put_env(:phoenix_kit_ecommerce, :api_image_download_opts,
        req_options: [plug: {Req.Test, @stub}]
      )

      on_exit(fn ->
        File.rm_rf(dir)
        Application.delete_env(:phoenix_kit_ecommerce, :api_image_download_opts)
      end)

      first = draw(dir, "first.png", 21)
      second = draw(dir, "second.png", 22)

      Req.Test.stub(@stub, fn conn ->
        body = if conn.request_path == "/a.png", do: first, else: second
        conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, body)
      end)

      %{catalogue: catalogue}
    end

    defp draw(dir, name, seed) do
      path = Path.join(dir, name)

      {_, 0} =
        System.cmd(
          "convert",
          ["-size", "320x240", "-seed", to_string(seed), "plasma:fractal", path],
          stderr_to_stdout: true
        )

      File.read!(path)
    end

    defp attach(item, paths, ctx) do
      images = Enum.map(paths, &%{"url" => @host <> &1})

      {:ok, _} =
        APICase.call("ecommerce.attach_images", %{"items" => [row(item, images)]}, ctx)

      F.reload!(item).data["media_order"]
    end

    defp status(uuid), do: Storage.get_file(uuid).status

    test "the only product that has a picture: the file is trashed, not deleted", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      [kept, gone] = attach(item, ["/a.png", "/b.png"], ctx)

      assert {:ok, %{"results" => [%{"detached" => 1}]}} = detach([row(item, ids([gone]))], ctx)

      assert F.reload!(item).data["media_order"] == [kept]
      assert status(gone) == "trashed"
      assert status(kept) == "active"
    end

    test "a picture is found by the URL it was attached from, query and all", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      [kept, gone] = attach(item, ["/a.png", "/b.png"], ctx)

      assert {:ok, %{"results" => [result]}} =
               detach([row(item, [%{"url" => @host <> "/b.png?sig=secret"}])], ctx)

      assert result["detached"] == 1
      refute inspect(result) =~ "secret"
      assert F.reload!(item).data["media_order"] == [kept]
      assert status(gone) == "trashed"
    end

    test "a URL that no stored picture came from is reported without its query", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      [kept] = attach(item, ["/a.png"], ctx)

      assert {:ok, %{"results" => [result], "summary" => %{"unchanged" => 1}}} =
               detach([row(item, [%{"url" => @host <> "/nope.png?sig=secret"}])], ctx)

      assert result["not_attached"] == [@host <> "/nope.png"]
      refute inspect(result) =~ "secret"
      assert F.reload!(item).data["media_order"] == [kept]
    end

    test "a picture another product shares stays alive and stays theirs", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      mine = F.item!(catalogue)
      theirs = F.item!(catalogue)
      [shared] = attach(mine, ["/a.png"], ctx)
      assert attach(theirs, ["/a.png"], ctx) == [shared]

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               detach([row(mine, ids([shared]))], confirmed(ctx))

      assert F.reload!(mine).data["media_order"] == []
      assert F.reload!(theirs).data["media_order"] == [shared]
      assert status(shared) == "active"

      # and the other way round: the one that held the link lets go of it
      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               detach([row(theirs, ids([shared]))], confirmed(ctx))

      assert status(shared) == "trashed"
    end

    test "a picture of another product is not removed by naming it", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      mine = F.item!(catalogue)
      theirs = F.item!(catalogue)
      [_own] = attach(mine, ["/a.png"], ctx)
      [foreign] = attach(theirs, ["/b.png"], ctx)

      assert {:ok, %{"results" => [result]}} = detach([row(mine, ids([foreign]))], ctx)

      assert result["action"] == "unchanged"
      assert result["not_attached"] == [foreign]
      assert F.reload!(theirs).data["media_order"] == [foreign]
      assert status(foreign) == "active"
    end
  end
end
