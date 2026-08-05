defmodule PhoenixKitEcommerce.Import.CSVParser do
  @moduledoc """
  Parse Shopify CSV and group rows by Handle.

  Shopify CSV structure:
  - First row with product data contains title, description, etc.
  - Subsequent rows for same Handle contain variant data only (empty title/description)
  - Each variant row has Option1/Option2 values and prices
  """

  NimbleCSV.define(ShopifyCSV, separator: ",", escape: "\"")

  # A Handle cannot contain a NUL, so a key built with this prefix can never
  # be one a merchant wrote.
  @blank_key_prefix "\0row:"

  @doc """
  Parse CSV file and group rows by Handle (product identifier).

  Returns a map where keys are handles and values are lists of row maps.

  ## Examples

      CSVParser.parse_and_group("/path/to/products.csv")
      # => %{
      #   "product-handle" => [
      #     %{"Handle" => "product-handle", "Title" => "Product", ...},
      #     %{"Handle" => "product-handle", "Option1 Value" => "Small", ...},
      #     ...
      #   ],
      #   ...
      # }
  """
  def parse_and_group(file_path) do
    {_headers, rows} =
      file_path
      |> File.stream!([:utf8])
      |> ShopifyCSV.parse_stream(skip_headers: false)
      |> Enum.reduce({nil, []}, fn
        row, {nil, []} ->
          # First row is headers
          {row, []}

        row, {headers, rows} ->
          # Convert row to map using headers
          row_map =
            Enum.zip(headers, row)
            |> Map.new()

          {headers, [row_map | rows]}
      end)

    # Group by Handle and reverse to maintain order
    rows
    |> Enum.reverse()
    |> group_rows()
  end

  @doc """
  The handle to import a group under — `nil` for a group the file gave no
  handle, so the product's slug is derived from its title instead.
  """
  def handle_value(key) do
    if blank_handle_key?(key), do: nil, else: key
  end

  @doc "A human-readable name for a group key, for logs and result tuples."
  def display_handle(key) do
    if blank_handle_key?(key),
      do: "(row #{String.trim_leading(key, @blank_key_prefix)})",
      else: key
  end

  defp blank_handle_key?(key) when is_binary(key), do: String.starts_with?(key, @blank_key_prefix)
  defp blank_handle_key?(_key), do: false

  # The handle is what makes a row a VARIANT of the row above it. Rows with a
  # blank handle share no such relationship, yet they all grouped under one
  # blank key: unrelated products merged into a single product, the first
  # row's title won, and the rest became its variants.
  #
  # Blank handle + blank title is Shopify's CONTINUATION shape, so it stays
  # with the group above it. Blank handle + a title starts a new group under a
  # synthetic key, which is namespaced so it can never collide with a real
  # handle in the same file (grouping by the slugified title did exactly that:
  # a handle-less "Mug" row was absorbed into the product handled `mug`).
  defp group_rows(rows) do
    {groups, _last_key, _index} =
      Enum.reduce(rows, {%{}, nil, 0}, fn row, {acc, last_key, index} ->
        {key, index} = next_group_key(row, last_key, index)
        {Map.update(acc, key, [row], &(&1 ++ [row])), key, index}
      end)

    groups
  end

  defp next_group_key(row, last_key, index) do
    handle = row["Handle"]
    title = row["Title"]

    cond do
      is_binary(handle) and handle != "" -> {handle, index}
      blank?(title) and not is_nil(last_key) -> {last_key, index}
      true -> {"#{@blank_key_prefix}#{index + 1}", index + 1}
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  @doc """
  Get the first (main) row for a product group.
  Contains title, description, and other product-level data.
  """
  def main_row(rows) when is_list(rows) do
    List.first(rows)
  end

  @doc """
  Get all variant rows (rows with price data).
  """
  def variant_rows(rows) when is_list(rows) do
    Enum.filter(rows, fn row ->
      price = row["Variant Price"]
      price != nil and price != ""
    end)
  end
end
