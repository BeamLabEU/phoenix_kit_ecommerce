defmodule PhoenixKitEcommerce.Shipping.LabelOptions do
  @moduledoc """
  How `print_labels/3` should lay the labels out: `format` is the paper
  size, `:a4` (the default), `:a5` or `:a6`. A carrier that cannot print a
  format answers with an error.
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  @formats [:a4, :a5, :a6]

  defstruct format: :a4

  @type format :: :a4 | :a5 | :a6

  @type t :: %__MODULE__{format: format()}

  @doc "The paper sizes a label can be asked in."
  @spec formats() :: [format()]
  def formats, do: @formats

  @doc "Serialises the options into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = options), do: Codec.encode(options)

  @doc "Builds options from a map with string or atom keys; an unknown format is `:a4`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = options), do: options

  def from_map(map) when is_map(map),
    do: %__MODULE__{format: map |> Codec.get(:format) |> Codec.atom(@formats) || :a4}

  def from_map(_other), do: nil
end
