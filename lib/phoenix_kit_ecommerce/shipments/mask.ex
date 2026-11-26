defmodule PhoenixKitEcommerce.Shipments.Mask do
  @moduledoc false
  # What a carrier says about a shipment is stored on it (`error`, `events`)
  # and shown to every admin who opens it. A carrier often echoes the
  # recipient back ("phone +372... is not valid for Maria Tamm"), so the text
  # is masked before it is stored: the recipient's own name, e-mail, phone and
  # street address become `[redacted]`, and anything else shaped like an
  # e-mail address or an international phone number becomes `[email]` or
  # `[phone]`. A phone (as normalised and as typed) is matched by its last
  # seven or more digits, with any spaces, dashes, dots or brackets between
  # them (the national form a carrier may print). The company is matched
  # whole. Values shorter than three characters are left alone.

  alias PhoenixKitEcommerce.Shipping.Codec

  @redacted "[redacted]"
  @min_length 3
  @phone_tail 7
  @address_parts [:street, :house, :apartment, :line]

  @doc "Masks `text` against the recipient and the destination of a shipment."
  @spec text(String.t() | nil, map(), map()) :: String.t() | nil
  def text(nil, _recipient, _destination), do: nil

  # A carrier's bytes need not be UTF-8: they are made valid first, or the
  # Unicode patterns below would raise.
  def text(text, recipient, destination) when is_binary(text) do
    recipient
    |> patterns(destination)
    |> Enum.reduce(String.replace_invalid(text), &Regex.replace(&1, &2, @redacted))
    |> then(
      &Regex.replace(~r/[^\s@<>"',;:()\[\]]+@[^\s@<>"',;:()\[\]]+\.[a-z]{2,}/iu, &1, "[email]")
    )
    |> then(&Regex.replace(~r/\+\d[\d\s\-\.\(\)]{6,}\d/u, &1, "[phone]"))
  end

  # The longest first, so a full name is replaced before its parts. A company
  # is replaced whole, never word by word: its words are ordinary words
  # ("Best Prints").
  defp patterns(recipient, destination) do
    name = recipient |> Codec.get(:name) |> Codec.string()
    address = destination |> Codec.get(:address) |> address_values()

    texts =
      [name, get(recipient, :company), get(recipient, :email)]
      |> Kernel.++(name_parts(name))
      |> Kernel.++(address)
      |> Enum.filter(&(is_binary(&1) and String.length(String.trim(&1)) >= @min_length))
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.map(&Regex.compile!(Regex.escape(&1), "iu"))

    phones =
      [get(recipient, :phone), get(recipient, :raw_phone)]
      |> Enum.flat_map(&digit_tails/1)
      |> Enum.uniq()
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.map(&digits_pattern/1)

    phones ++ texts
  end

  defp get(map, key), do: map |> Codec.get(key) |> Codec.string()

  defp name_parts(name) when is_binary(name), do: String.split(name, ~r/\s+/u, trim: true)
  defp name_parts(_name), do: []

  # The last seven or more digits of a number, however the carrier groups
  # them ("5555 1234", "55-55-12-34").
  defp digit_tails(phone) when is_binary(phone) do
    digits = String.replace(phone, ~r/\D/u, "")

    for length <- String.length(digits)..@phone_tail//-1,
        length >= @phone_tail,
        do: String.slice(digits, -length, length)
  end

  defp digit_tails(_phone), do: []

  defp digits_pattern(digits) do
    digits
    |> String.graphemes()
    |> Enum.join("[\\s\\-\\.\\(\\)]*")
    |> then(&Regex.compile!("(?<!\\d)\\+?" <> &1 <> "(?!\\d)", "u"))
  end

  defp address_values(address) when is_map(address) do
    Enum.map(@address_parts, &(address |> Codec.get(&1) |> Codec.string()))
  end

  defp address_values(_address), do: []
end
