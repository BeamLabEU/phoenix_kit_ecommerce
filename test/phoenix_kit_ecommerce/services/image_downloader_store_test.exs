defmodule PhoenixKitEcommerce.Services.ImageDownloaderStoreTest do
  @moduledoc """
  `ImageDownloader.download_and_store/3` against real Storage rows: which
  existing file it hands back instead of storing a second copy, and what
  it records on the way. HTTP goes through `Req.Test`'s plug adapter
  (public literal address, so the SSRF guard needs no DNS); the image
  bytes are real pictures drawn with ImageMagick, so the fingerprint is
  the one production computes. Skipped where ImageMagick is missing.

  `async: false`: the near-duplicate lookup reads every imported file,
  and these tests reason about exactly which rows exist.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.Test.Repo

  @moduletag skip:
               if(System.find_executable("convert"),
                 do: false,
                 else: "ImageMagick (convert) is not installed"
               )

  @stub __MODULE__
  @host "https://93.184.216.34"

  setup do
    dir =
      Path.join(System.tmp_dir!(), "image_downloader_store_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    banner = draw(dir, "banner.png", 7)

    %{
      user: fixture_user(),
      banner: File.read!(banner),
      banner_jpeg: File.read!(reencode(banner, Path.join(dir, "banner.jpg"), ["-quality", "70"])),
      other: File.read!(draw(dir, "other.png", 8))
    }
  end

  # A fractal texture: as stable a fingerprint under re-encoding as a photo.
  defp draw(dir, name, seed) do
    path = Path.join(dir, name)

    {_, 0} =
      System.cmd(
        "convert",
        ["-size", "320x240", "-seed", to_string(seed), "plasma:fractal", path],
        stderr_to_stdout: true
      )

    path
  end

  defp reencode(source, dest, args) do
    {_, 0} = System.cmd("convert", [source | args] ++ [dest], stderr_to_stdout: true)
    dest
  end

  # Serves `routes` (`%{"/path" => {content_type, body}}`) and returns the
  # options `download_and_store/3` needs to use the stub.
  defp serve(routes) do
    Req.Test.stub(@stub, fn conn ->
      {type, body} = Map.fetch!(routes, conn.request_path)

      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(200, body)
    end)

    [req_options: [plug: {Req.Test, @stub}]]
  end

  defp file!(uuid), do: Storage.get_file(uuid)

  test "a new picture is stored with its fingerprint and source", %{user: user, banner: banner} do
    opts = serve(%{"/a.png" => {"image/png", banner}})

    assert {:ok, uuid} = ImageDownloader.download_and_store("#{@host}/a.png?v=1", user.uuid, opts)

    file = file!(uuid)
    assert file.status == "active"
    assert file.metadata["source_url"] == "#{@host}/a.png?v=1"
    assert "v1:" <> _ = file.metadata["image_fingerprint"]
  end

  test "a re-encoded copy at another URL reuses the stored file and remembers that URL", %{
    user: user,
    banner: banner,
    banner_jpeg: banner_jpeg
  } do
    opts =
      serve(%{"/a.png" => {"image/png", banner}, "/copy.jpg" => {"image/jpeg", banner_jpeg}})

    {:ok, original} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    count = Repo.aggregate(Storage.File, :count)

    assert {:ok, ^original} =
             ImageDownloader.download_and_store("#{@host}/copy.jpg?v=7", user.uuid, opts)

    assert Repo.aggregate(Storage.File, :count) == count
    assert file!(original).metadata["source_url_aliases"] == ["#{@host}/copy.jpg"]

    # Resolving the same URL again does not grow the list.
    assert {:ok, ^original} =
             ImageDownloader.download_and_store("#{@host}/copy.jpg?v=8", user.uuid, opts)

    assert file!(original).metadata["source_url_aliases"] == ["#{@host}/copy.jpg"]
  end

  test "a different picture is stored as a new file", %{user: user, banner: banner, other: other} do
    opts = serve(%{"/a.png" => {"image/png", banner}, "/b.png" => {"image/png", other}})

    {:ok, a} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    {:ok, b} = ImageDownloader.download_and_store("#{@host}/b.png", user.uuid, opts)

    refute a == b
    refute Map.has_key?(file!(a).metadata, "source_url_aliases")
  end

  test "a trashed file is never handed back, by checksum or by fingerprint", %{
    user: user,
    banner: banner,
    banner_jpeg: banner_jpeg
  } do
    other_user = fixture_user()

    opts =
      serve(%{"/a.png" => {"image/png", banner}, "/copy.jpg" => {"image/jpeg", banner_jpeg}})

    {:ok, trashed} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    {:ok, _} = Storage.trash_file(trashed)

    # Same bytes, same name — another uploader, so core's own per-user
    # dedup does not answer first and only this module's lookup decides.
    assert {:ok, again} =
             ImageDownloader.download_and_store("#{@host}/a.png", other_user.uuid, opts)

    refute again == trashed
    assert file!(again).status == "active"

    {:ok, _} = Storage.trash_file(again)

    assert {:ok, copy} =
             ImageDownloader.download_and_store("#{@host}/copy.jpg", other_user.uuid, opts)

    refute copy in [trashed, again]
  end

  test "near_duplicates: false stores the copy and computes no fingerprint", %{
    user: user,
    banner: banner,
    banner_jpeg: banner_jpeg
  } do
    opts =
      serve(%{"/a.png" => {"image/png", banner}, "/copy.jpg" => {"image/jpeg", banner_jpeg}})

    {:ok, original} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)

    assert {:ok, copy} =
             ImageDownloader.download_and_store(
               "#{@host}/copy.jpg",
               user.uuid,
               opts ++ [near_duplicates: false]
             )

    refute copy == original
    refute Map.has_key?(file!(copy).metadata, "image_fingerprint")
  end

  describe "backfill_fingerprints/1" do
    test "fingerprints imported images that predate fingerprints, and only those", %{
      user: user,
      banner: banner,
      other: other
    } do
      imported = store_raw(banner, "old.png", user.uuid, %{"source_url" => "#{@host}/old.png"})
      uploaded = store_raw(other, "own.png", user.uuid, %{})

      assert %{fingerprinted: 1, failed: 0} = ImageDownloader.backfill_fingerprints()
      assert "v1:" <> _ = file!(imported).metadata["image_fingerprint"]
      refute Map.has_key?(file!(uploaded).metadata || %{}, "image_fingerprint")

      # Nothing left to do on a second run.
      assert %{fingerprinted: 0, failed: 0} = ImageDownloader.backfill_fingerprints()
    end

    test "a backfilled file is then found as the same picture", %{
      user: user,
      banner: banner,
      banner_jpeg: banner_jpeg
    } do
      old = store_raw(banner, "old.png", user.uuid, %{"source_url" => "#{@host}/old.png"})
      ImageDownloader.backfill_fingerprints()

      opts = serve(%{"/copy.jpg" => {"image/jpeg", banner_jpeg}})

      assert {:ok, ^old} =
               ImageDownloader.download_and_store("#{@host}/copy.jpg", user.uuid, opts)
    end
  end

  # A file stored the way an import before fingerprints did: Storage row,
  # given metadata, no `image_fingerprint`.
  defp store_raw(bytes, name, user_uuid, metadata) do
    tmp = Path.join(System.tmp_dir!(), "store_raw_#{System.unique_integer([:positive])}_#{name}")
    File.write!(tmp, bytes)

    {:ok, file} =
      Storage.store_file(tmp,
        filename: name,
        content_type: "image/png",
        size_bytes: byte_size(bytes),
        user_uuid: user_uuid,
        metadata: metadata
      )

    File.rm(tmp)
    file.uuid
  end
end
