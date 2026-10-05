defmodule PhoenixKitEcommerce.Services.ImageFingerprintTest do
  @moduledoc """
  `PhoenixKitEcommerce.Services.ImageFingerprint`: the perceptual
  fingerprint `ImageDownloader` uses to recognise a re-encoded or resized
  copy of a picture it already stored.

  `match?/2` and `compare/2` are pure and run everywhere. `compute/1`
  shells out to ImageMagick, so its tests draw real images with `convert`
  and are skipped where ImageMagick is not installed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Services.ImageFingerprint

  @magick System.find_executable("convert")

  # A fingerprint built by hand: 32 bytes of hash, 48 bytes of color.
  defp fp(hash_bytes, color_bytes) do
    "v1:" <>
      Base.encode16(hash_bytes, case: :lower) <> ":" <> Base.encode16(color_bytes, case: :lower)
  end

  defp hash_with_bits_set(n), do: <<-1::size(n), 0::size(256 - n)>>
  defp zero_hash, do: <<0::256>>
  defp grey(value), do: :binary.copy(<<value>>, 48)

  describe "compare/2 and match?/2" do
    test "an identical fingerprint matches with zero distance" do
      a = fp(zero_hash(), grey(100))

      assert {:ok, %{bits: 0, mean_color: +0.0, max_color: 0}} = ImageFingerprint.compare(a, a)
      assert ImageFingerprint.match?(a, a)
    end

    test "up to 8 differing hash bits match, 9 do not" do
      a = fp(zero_hash(), grey(100))

      assert ImageFingerprint.match?(a, fp(hash_with_bits_set(8), grey(100)))
      refute ImageFingerprint.match?(a, fp(hash_with_bits_set(9), grey(100)))
    end

    test "a uniform color shift of 4 matches, 5 does not" do
      a = fp(zero_hash(), grey(100))

      assert ImageFingerprint.match?(a, fp(zero_hash(), grey(104)))
      refute ImageFingerprint.match?(a, fp(zero_hash(), grey(105)))
    end

    test "one cell off by more than 12 does not match even when the mean is small" do
      # The light-pink vs light-grey brick wall seen in a live library: the
      # same room photographed with two wall colors averages out to a
      # small mean difference, but one region differs strongly.
      a = fp(zero_hash(), grey(100))
      b = fp(zero_hash(), <<113>> <> :binary.copy(<<100>>, 47))
      c = fp(zero_hash(), <<112>> <> :binary.copy(<<100>>, 47))

      refute ImageFingerprint.match?(a, b)
      assert ImageFingerprint.match?(a, c)
    end

    test "a malformed or foreign-version fingerprint never matches" do
      a = fp(zero_hash(), grey(100))

      refute ImageFingerprint.match?(a, "v0:" <> String.slice(a, 3..-1//1))
      refute ImageFingerprint.match?(a, "v1:abc:def")
      refute ImageFingerprint.match?(a, nil)
      assert ImageFingerprint.compare(a, "garbage") == :error
    end
  end

  describe "compute/1" do
    @describetag skip: if(@magick, do: false, else: "ImageMagick (convert) is not installed")

    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "image_fingerprint_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    # A fractal texture: structure everywhere, so the hash is stable
    # under re-encoding the way a photo's is (a flat gradient is not — its
    # neighbouring pixels are nearly equal and JPEG noise flips them).
    defp draw(dir, name, seed, extra \\ []) do
      path = Path.join(dir, name)

      {_, 0} =
        System.cmd(
          "convert",
          ["-size", "320x240", "-seed", to_string(seed), "plasma:fractal"] ++ extra ++ [path],
          stderr_to_stdout: true
        )

      path
    end

    defp reencode(source, dest, args) do
      {_, 0} = System.cmd("convert", [source | args] ++ [dest], stderr_to_stdout: true)
      dest
    end

    test "returns a versioned fingerprint", %{dir: dir} do
      assert {:ok, "v1:" <> rest} = ImageFingerprint.compute(draw(dir, "a.png", 7))
      assert [hash, color] = String.split(rest, ":")
      assert byte_size(hash) == 64
      assert byte_size(color) == 96
    end

    test "a re-encoded copy matches the original", %{dir: dir} do
      original = draw(dir, "a.png", 7)
      jpeg = reencode(original, Path.join(dir, "a.jpg"), ["-quality", "70"])

      {:ok, a} = ImageFingerprint.compute(original)
      {:ok, b} = ImageFingerprint.compute(jpeg)

      assert ImageFingerprint.match?(a, b)
    end

    test "a downscaled copy matches the original", %{dir: dir} do
      original = draw(dir, "a.png", 7)
      small = reencode(original, Path.join(dir, "small.png"), ["-resize", "50%"])

      {:ok, a} = ImageFingerprint.compute(original)
      {:ok, b} = ImageFingerprint.compute(small)

      assert ImageFingerprint.match?(a, b)
    end

    test "the same composition in another color does not match", %{dir: dir} do
      original = draw(dir, "a.png", 7)
      recolored = reencode(original, Path.join(dir, "hue.png"), ["-modulate", "100,100,150"])

      {:ok, a} = ImageFingerprint.compute(original)
      {:ok, b} = ImageFingerprint.compute(recolored)

      refute ImageFingerprint.match?(a, b)
    end

    test "a different picture does not match", %{dir: dir} do
      {:ok, a} = ImageFingerprint.compute(draw(dir, "a.png", 7))
      {:ok, b} = ImageFingerprint.compute(draw(dir, "b.png", 8))
      {:ok, mirrored} = ImageFingerprint.compute(draw(dir, "flop.png", 7, ["-flop"]))

      refute ImageFingerprint.match?(a, b)
      refute ImageFingerprint.match?(a, mirrored)
    end

    test "a file that is not an image is an error, not a fingerprint", %{dir: dir} do
      path = Path.join(dir, "not-an-image.jpg")
      File.write!(path, "<svg xmlns='http://www.w3.org/2000/svg'/>")

      assert {:error, _reason} = ImageFingerprint.compute(path)
    end
  end
end
