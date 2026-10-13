defmodule PhoenixKitEcommerce.API.AttachImagesTest do
  @moduledoc """
  `ecommerce.attach_images` against a real catalogue and real Storage rows:
  pictures are downloaded, stored and appended; a known URL is reused; the
  private-network guard holds even with the shop's import setting on; a dry
  run fetches nothing.

  HTTP goes through `Req.Test`'s plug adapter (the hook
  `config :phoenix_kit_ecommerce, :api_image_download_opts`), never the
  network. The pictures are drawn with ImageMagick, as in the downloader's
  own store tests; skipped where it is missing. `async: false`: it reads the
  shop-wide URL index and flips settings.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api
  @moduletag :core_confirm
  @moduletag skip:
               if(System.find_executable("convert"),
                 do: false,
                 else: "ImageMagick (convert) is not installed"
               )

  import ExUnit.CaptureLog, only: [with_log: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.API.AttachImages
  alias PhoenixKitEcommerce.APICase
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.StorefrontCache

  @stub __MODULE__
  @host "https://93.184.216.34"

  setup do
    dir = Path.join(System.tmp_dir!(), "attach_images_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Application.put_env(:phoenix_kit_ecommerce, :api_image_download_opts,
      req_options: [plug: {Req.Test, @stub}]
    )

    on_exit(fn ->
      File.rm_rf(dir)
      Application.delete_env(:phoenix_kit_ecommerce, :api_image_download_opts)

      Settings.update_boolean_setting_with_module(
        "shop_image_import_allow_private_networks",
        false,
        "shop"
      )
    end)

    catalogue = F.shop_catalogue!()
    user = F.user!()

    %{
      catalogue: catalogue,
      user: user,
      ctx: F.ctx(user),
      first: draw(dir, "first.png", 11),
      second: draw(dir, "second.png", 12)
    }
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

  # Serves `%{"/path" => {content_type, body}}` and reports each request to the test.
  defp serve(routes) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, {:requested, conn.request_path})
      {type, body} = Map.fetch!(routes, conn.request_path)
      conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp attach(rows, ctx), do: APICase.call("ecommerce.attach_images", %{"items" => rows}, ctx)

  # The handler without the schema in front of it: for the test that pins the
  # planner's own second line of defence (a scheme the schema already refuses).
  defp attach_raw(rows, ctx), do: AttachImages.run(%{"items" => rows}, ctx)

  defp row(item, images), do: %{"ref" => %{"id" => item.uuid}, "images" => images}
  defp image(path, extra \\ %{}), do: Map.merge(%{"url" => @host <> path}, extra)

  test "downloads, stores and appends pictures; the first becomes the featured one",
       %{catalogue: catalogue, ctx: ctx, first: first, second: second} do
    item = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}, "/b.png" => {"image/png", second}})

    assert {:ok, %{"results" => [result], "summary" => %{"updated" => 1}}} =
             attach([row(item, [image("/a.png"), image("/b.png")])], ctx)

    assert result["action"] == "updated"
    assert result["attached"] == 2
    assert result["downloaded"] == 2
    assert result["reused"] == 0
    assert result["failed"] == []

    data = F.reload!(item).data
    assert [one, two] = data["media_order"]
    assert one != two
    assert data["featured_image_uuid"] == one
  end

  test "new pictures go after the ones the product has, and a featured flag moves the main one",
       %{catalogue: catalogue, ctx: ctx, first: first, second: second} do
    item = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}, "/b.png" => {"image/png", second}})

    assert {:ok, _} = attach([row(item, [image("/a.png")])], ctx)
    [first_uuid] = F.reload!(item).data["media_order"]

    assert {:ok, %{"results" => [%{"attached" => 1}]}} =
             attach([row(item, [image("/b.png", %{"featured" => true})])], ctx)

    data = F.reload!(item).data
    assert [^first_uuid, second_uuid] = data["media_order"]
    assert data["featured_image_uuid"] == second_uuid
  end

  test "a URL that is already stored is reused without a request", %{
    catalogue: catalogue,
    ctx: ctx,
    first: first
  } do
    one = F.item!(catalogue)
    two = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}})

    assert {:ok, _} = attach([row(one, [image("/a.png")])], ctx)
    assert_received {:requested, "/a.png"}

    assert {:ok, %{"results" => [result]}} = attach([row(two, [image("/a.png")])], ctx)
    refute_received {:requested, _}

    assert result["reused"] == 1
    assert result["downloaded"] == 0
    assert F.reload!(one).data["media_order"] == F.reload!(two).data["media_order"]
  end

  test "private addresses and other schemes are refused even with the import setting on, and nothing is fetched",
       %{catalogue: catalogue, ctx: ctx} do
    Settings.update_boolean_setting_with_module(
      "shop_image_import_allow_private_networks",
      true,
      "shop"
    )

    serve(%{})
    item = F.item!(catalogue)

    # private addresses pass the schema (they are http(s) URLs) and are refused by the planner
    for url <- ["http://127.0.0.1/a.png", "https://10.0.0.5/a.png", "https://169.254.169.254/x"] do
      assert {:ok, %{"results" => [result]}} = attach([row(item, [%{"url" => url}])], ctx)

      assert result["action"] == "error", "#{url} must be refused"
      assert result["error"]["code"] == "validation_failed"
      assert [%{"path" => "images[0].url"}] = result["error"]["context"]["errors"]
    end

    # other schemes: the schema refuses them before any handler runs ...
    for url <- ["file:///etc/passwd", "ftp://93.184.216.34/a.png"] do
      assert {:error, :validation_failed, _message, %{errors: [%{path: path} | _]}} =
               attach([row(item, [%{"url" => url}])], ctx)

      assert path == "items[0].images[0].url", "#{url} must be refused by the schema"

      # ... and the planner refuses them too, were one to get past it
      assert {:ok, %{"results" => [result]}} = attach_raw([row(item, [%{"url" => url}])], ctx)
      assert result["action"] == "error"
      assert [%{"path" => "images[0].url"}] = result["error"]["context"]["errors"]
    end

    refute_received {:requested, _}
    assert F.reload!(item).data["media_order"] in [nil, []]
  end

  test "a redirect to a private address fails the picture and attaches nothing", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    Settings.update_boolean_setting_with_module(
      "shop_image_import_allow_private_networks",
      true,
      "shop"
    )

    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://127.0.0.1/secret.png")
      |> Plug.Conn.send_resp(302, "")
    end)

    item = F.item!(catalogue)

    assert {:ok, %{"results" => [result]}} = attach([row(item, [image("/a.png")])], ctx)

    assert result["action"] == "error"
    assert [%{"reason" => reason}] = result["error"]["context"]["images"]
    assert reason =~ "private"
    assert F.reload!(item).data["media_order"] in [nil, []]
  end

  test "a picture that fails does not hide the one that worked", %{
    catalogue: catalogue,
    ctx: ctx,
    first: first
  } do
    item = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}, "/doc.pdf" => {"application/pdf", "%PDF"}})

    assert {:ok, %{"results" => [result]}} =
             attach([row(item, [image("/a.png"), image("/doc.pdf?token=secret")])], ctx)

    assert result["action"] == "updated"
    assert result["attached"] == 1
    assert [%{"url" => failed_url}] = result["failed"]
    assert failed_url == @host <> "/doc.pdf"
    refute inspect(result) =~ "secret"
  end

  test "a dry run checks the URLs and fetches nothing", %{catalogue: catalogue, ctx: ctx} do
    serve(%{})
    item = F.item!(catalogue)

    rows = [
      row(item, [image("/a.png")]),
      %{"ref" => %{"sku" => "NONE"}, "images" => [image("/b.png")]}
    ]

    assert {:preview, preview, fingerprint} = attach(rows, %{ctx | dry_run?: true})

    assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert Enum.map(preview["rows"], & &1["action"]) == ["update", "error"]
    refute_received {:requested, _}
    assert F.reload!(item).data["media_order"] in [nil, []]
  end

  test "more than 20 pictures in a call are refused before anything happens", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    one = F.item!(catalogue)
    two = F.item!(catalogue)
    first = for n <- 1..11, do: image("/#{n}.png")
    second = for n <- 12..21, do: image("/#{n}.png")

    # 11 + 10: each row is within the schema's 20 per row, the call is not
    assert {:error, :validation_failed, _detail, %{errors: [%{path: "items", limit: 20}]}} =
             attach([row(one, first), row(two, second)], ctx)

    # 21 in one row is refused earlier, by the schema
    assert {:error, :validation_failed, _detail, %{errors: [%{path: path} | _]}} =
             attach([row(one, first ++ second)], ctx)

    assert path == "items[0].images"
  end

  test "two featured pictures in one row are refused", %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)

    assert {:ok, %{"results" => [result]}} =
             attach(
               [
                 row(item, [
                   image("/a.png", %{"featured" => true}),
                   image("/b.png", %{"featured" => true})
                 ])
               ],
               ctx
             )

    assert result["error"]["code"] == "validation_failed"
  end

  test "logs the attachment with the API metadata and no URLs", %{
    catalogue: catalogue,
    user: user,
    ctx: ctx,
    first: first
  } do
    item = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}})

    assert {:ok, _} = attach([row(item, [image("/a.png?sig=abc")])], ctx)

    entry =
      assert_activity_logged("shop.api_images_attached",
        resource_uuid: item.uuid,
        actor_uuid: user.uuid,
        metadata_has: %{"via" => "api", "tool" => "ecommerce.attach_images", "attached" => 1}
      )

    refute inspect(entry) =~ "sig=abc"
  end

  test "a signed URL's query string reaches no log line, no stored file metadata, no activity entry and no answer",
       %{catalogue: catalogue, user: user, ctx: ctx, first: first} do
    # The test environment logs from :warning up; the downloader's lines that
    # carried the URL are :info, so raise the level for this test only.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    item = F.item!(catalogue)
    serve(%{"/signed.png" => {"image/png", first}, "/doc.pdf" => {"application/pdf", "%PDF"}})

    {answer, log} =
      with_log([level: :info], fn ->
        attach(
          [
            row(item, [
              image("/signed.png?X-Amz-Signature=sekrit"),
              image("/doc.pdf?X-Amz-Signature=sekrit")
            ])
          ],
          ctx
        )
      end)

    assert {:ok, %{"results" => [result]}} = answer
    assert result["attached"] == 1
    assert [%{"url" => failed_url}] = result["failed"]
    assert failed_url == @host <> "/doc.pdf"

    # The lines were emitted (the picture's path is in them) and carry no query.
    assert log =~ "signed.png"
    refute log =~ "sekrit"
    refute log =~ "X-Amz-Signature"
    refute inspect(result) =~ "sekrit"

    # The stored file remembers the URL without the credential.
    [file_uuid] = F.reload!(item).data["media_order"]
    file = Storage.get_file(file_uuid)
    assert file.metadata["source_url"] == @host <> "/signed.png"
    refute inspect(file.metadata) =~ "sekrit"

    entry =
      assert_activity_logged("shop.api_images_attached",
        resource_uuid: item.uuid,
        actor_uuid: user.uuid
      )

    refute inspect(entry) =~ "sekrit"
  end

  test "a picture stored earlier by the importer under a URL with a query is reused for the same URL with another query",
       %{catalogue: catalogue, user: user, ctx: ctx, first: first} do
    serve(%{"/a.png" => {"image/png", first}})

    assert {:ok, file_uuid} =
             ImageDownloader.download_and_store(@host <> "/a.png?v=1", user.uuid,
               req_options: [plug: {Req.Test, @stub}]
             )

    assert_received {:requested, "/a.png"}

    item = F.item!(catalogue)
    assert {:ok, %{"results" => [result]}} = attach([row(item, [image("/a.png?v=2")])], ctx)

    refute_received {:requested, _}
    assert result["reused"] == 1
    assert F.reload!(item).data["media_order"] == [file_uuid]
  end

  test "a picture over the API's size limit fails its row", %{catalogue: catalogue, ctx: ctx} do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, :binary.copy("x", AttachImages.max_image_bytes() + 1))
    end)

    item = F.item!(catalogue)

    assert {:ok, %{"results" => [result]}} = attach([row(item, [image("/big.png")])], ctx)

    assert result["action"] == "error"
    assert [%{"reason" => reason}] = result["error"]["context"]["images"]
    assert reason =~ "exceeds limit"
    assert F.reload!(item).data["media_order"] in [nil, []]
  end

  describe "the storefront cache" do
    setup do
      start_supervised!(PhoenixKit.Cache.Registry)
      [spec] = StorefrontCache.children()
      start_supervised!(spec)
      :ok
    end

    test "a stored picture clears it; a dry run and a failed row leave it", %{
      catalogue: catalogue,
      ctx: ctx,
      first: first
    } do
      item = F.item!(catalogue)
      serve(%{"/a.png" => {"image/png", first}, "/doc.pdf" => {"application/pdf", "%PDF"}})

      :stale = StorefrontCache.fetch(:probe, fn -> :stale end)

      assert {:preview, _, _} = attach([row(item, [image("/a.png")])], %{ctx | dry_run?: true})

      assert {:ok, %{"summary" => %{"error" => 1}}} =
               attach([row(item, [image("/doc.pdf")])], ctx)

      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               attach([row(item, [image("/a.png")])], ctx)

      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh
    end
  end

  test "the legacy source is refused", %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)
    F.put_config!("shop_product_source", "legacy")

    assert {:error, :unsupported_source, _detail, %{reason: "legacy_source"}} =
             attach([row(item, [image("/a.png")])], ctx)
  end
end
