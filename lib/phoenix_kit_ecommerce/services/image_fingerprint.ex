defmodule PhoenixKitEcommerce.Services.ImageFingerprint do
  @moduledoc """
  A perceptual fingerprint of an image: what lets `ImageDownloader` tell a
  re-encoded, re-saved or downscaled copy of a picture it already stored
  apart from a genuinely different picture.

  Byte checksums cannot do that. A Shopify store that was filled from Etsy
  holds the same banner ("Thank you for your support", a filament color
  chart, a care card) as a separate file on every listing — each with its
  own CDN URL and bytes that differ by a few dozen bytes — so an import
  keyed on URL or checksum downloads every copy. One live library held 389
  files for 13 such pictures.

  ## The fingerprint

  One ImageMagick call scales the image to 17×16 RGB. From those pixels:

    * a 256-bit difference hash (dHash) of the luma: for each of the 16
      rows, whether each pixel is darker than its right-hand neighbour —
      the picture's structure, insensitive to re-encoding and scale;
    * a 4×4 grid of mean RGB values (48 bytes) — its colors, which the
      luma hash cannot see (the same room with a pink and with a grey
      wall hashes alike).

  Stored as `"v1:<64 hex hash>:<96 hex colors>"`.

  ## The match

  Two fingerprints match when the hashes differ in at most 8 bits, the
  colors differ by at most 4 on average and by at most 12 in any single
  cell. Measured on a live library of 3,121 images: this joins 373 of the
  376 redundant copies of 13 shared banners and 139 groups of duplicated
  product photos, and no pair of different pictures — the single-cell
  bound is what keeps two color variants of one product photo apart, the
  256-bit hash what keeps two objects photographed on the same plain
  background apart (an 8×8 hash with no color check joined both).

  ImageMagick runs with core's resource limits and with its decoder
  pinned to the format the file's bytes sniff as
  (`PhoenixKit.Modules.Storage.ImageProcessor`), the same envelope every
  other ImageMagick call in PhoenixKit runs in.
  """

  require Logger

  alias PhoenixKit.Modules.Storage.ImageProcessor

  @version "v1"
  @width 17
  @height 16
  @raw_size @width * @height * 3

  @max_hash_bits 8
  @max_mean_color 4
  @max_cell_color 12

  @typedoc "`\"v1:<64 hex>:<96 hex>\"`"
  @type t :: String.t()

  @doc """
  Computes the fingerprint of the image at `path`.

  Returns `{:error, reason}` for anything ImageMagick cannot read as a
  raster image (SVG included — the decoder is pinned to the sniffed
  format) and when ImageMagick is not installed.
  """
  @spec compute(Path.t()) :: {:ok, t()} | {:error, term()}
  def compute(path) when is_binary(path) do
    with {:ok, input} <- ImageProcessor.pinned_input(path, "[0]"),
         {:ok, raw} <- scale(input) do
      {:ok, encode(raw)}
    end
  rescue
    # `System.cmd/3` raises when the executable is missing altogether.
    e -> {:error, {:fingerprint_failed, Exception.message(e)}}
  end

  defp scale(input) do
    args =
      ImageProcessor.limit_args() ++
        [
          input,
          "-colorspace",
          "sRGB",
          "-resize",
          "#{@width}x#{@height}!",
          "-depth",
          "8",
          "rgb:-"
        ]

    case System.cmd("convert", args, stderr_to_stdout: false) do
      {raw, 0} when byte_size(raw) == @raw_size -> {:ok, raw}
      {_out, 0} -> {:error, :unexpected_output}
      {_out, code} -> {:error, {:convert_failed, code}}
    end
  end

  defp encode(raw) do
    rows =
      for <<row::binary-size(@width * 3) <- raw>> do
        for(<<r, g, b <- row>>, do: {r, g, b}) |> List.to_tuple()
      end
      |> List.to_tuple()

    hash =
      for y <- 0..(@height - 1), x <- 0..(@width - 2), into: <<>> do
        left = luma(pixel(rows, x, y))
        right = luma(pixel(rows, x + 1, y))
        if left < right, do: <<1::1>>, else: <<0::1>>
      end

    colors =
      for by <- 0..3, bx <- 0..3, channel <- 0..2, into: <<>> do
        sum =
          for dy <- 0..3, dx <- 0..3, reduce: 0 do
            acc -> acc + elem(pixel(rows, bx * 4 + dx, by * 4 + dy), channel)
          end

        <<div(sum, 16)>>
      end

    Enum.join(
      [@version, Base.encode16(hash, case: :lower), Base.encode16(colors, case: :lower)],
      ":"
    )
  end

  defp pixel(rows, x, y), do: rows |> elem(y) |> elem(x)

  # Rec. 601 luma, in integers.
  defp luma({r, g, b}), do: div(299 * r + 587 * g + 114 * b, 1000)

  @doc """
  The distances between two fingerprints: differing hash bits, the mean
  and the largest per-cell color difference. `:error` when either is not
  a well-formed fingerprint of this version.
  """
  @spec compare(term(), term()) ::
          {:ok, %{bits: non_neg_integer(), mean_color: float(), max_color: non_neg_integer()}}
          | :error
  def compare(a, b) do
    with {:ok, {hash_a, colors_a}} <- decode(a),
         {:ok, {hash_b, colors_b}} <- decode(b) do
      bits = for <<bit::1 <- :crypto.exor(hash_a, hash_b)>>, reduce: 0, do: (acc -> acc + bit)

      diffs =
        Enum.zip_with(:binary.bin_to_list(colors_a), :binary.bin_to_list(colors_b), &abs(&1 - &2))

      {:ok,
       %{bits: bits, mean_color: Enum.sum(diffs) / length(diffs), max_color: Enum.max(diffs)}}
    end
  end

  @doc """
  Whether two fingerprints are the same picture (see the module doc for
  the bounds and the measurement behind them). Anything malformed, or of
  another version, never matches.
  """
  @spec match?(term(), term()) :: boolean()
  def match?(a, b) do
    case compare(a, b) do
      {:ok, %{bits: bits, mean_color: mean, max_color: max}} ->
        bits <= @max_hash_bits and mean <= @max_mean_color and max <= @max_cell_color

      :error ->
        false
    end
  end

  defp decode(@version <> ":" <> rest) do
    with [hash_hex, colors_hex] <- String.split(rest, ":"),
         {:ok, <<_::256>> = hash} <- Base.decode16(hash_hex, case: :mixed),
         {:ok, <<_::384>> = colors} <- Base.decode16(colors_hex, case: :mixed) do
      {:ok, {hash, colors}}
    else
      _ -> :error
    end
  end

  defp decode(_other), do: :error
end
