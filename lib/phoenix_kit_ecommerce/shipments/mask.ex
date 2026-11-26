defmodule PhoenixKitEcommerce.Shipments.Mask do
  @moduledoc false
  # What a carrier says about a shipment is stored on it (`error`, `events`)
  # and shown to every admin who opens it. A carrier often echoes the
  # recipient back ("phone +372... is not valid for Maria Tamm"), so the text
  # is masked before it is stored: the recipient's own name, e-mail, phone and
  # street address become `[redacted]`, and anything else shaped like an
  # e-mail address or an international phone number becomes `[email]` or
  # `[phone]`. A phone is also matched without its `+` and by its last seven
  # or more digits (the national form a carrier may print). Values shorter
  # than three characters are left alone.

  alias PhoenixKitEcommerce.Shipping.Codec

  @redacted "[redacted]"
  @min_length 3
  @phone_tail 7
  @address_parts [:street, :house, :apartment, :line]

  @doc "Masks `text` against the recipient and the destination of a shipment."
  @spec text(String.t() | nil, map(), map()) :: String.t() | nil
  def text(nil, _recipient, _destination), do: nil

  def text(text, recipient, destination) when is_binary(text) do
    recipient
    |> sensitive(destination)
    |> Enum.reduce(text, fn value, acc ->
      Regex.replace(Regex.compile!(Regex.escape(value), "iu"), acc, @redacted)
    end)
    |> then(
      &Regex.replace(~r/[^\s@<>"',;:()\[\]]+@[^\s@<>"',;:()\[\]]+\.[a-z]{2,}/iu, &1, "[email]")
    )
    |> then(&Regex.replace(~r/\+\d[\d\s\-\.\(\)]{6,}\d/u, &1, "[phone]"))
  end

  # The longest first, so a full name is replaced before its parts.
  defp sensitive(recipient, destination) do
    name = recipient |> Codec.get(:name) |> Codec.string()
    phone = recipient |> Codec.get(:phone) |> Codec.string()
    address = destination |> Codec.get(:address) |> address_values()

    [name, recipient |> Codec.get(:email) |> Codec.string(), phone]
    |> Kernel.++(digit_tails(phone))
    |> Kernel.++(name_parts(name))
    |> Kernel.++(address)
    |> Enum.filter(&(is_binary(&1) and String.length(String.trim(&1)) >= @min_length))
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.sort_by(&String.length/1, :desc)
  end

  defp name_parts(name) when is_binary(name), do: String.split(name, ~r/\s+/u, trim: true)
  defp name_parts(_name), do: []

  defp digit_tails("+" <> digits) do
    for length <- String.length(digits)..@phone_tail//-1,
        length >= @phone_tail,
        do: String.slice(digits, -length, length)
  end

  defp digit_tails(_phone), do: []

  defp address_values(address) when is_map(address) do
    Enum.map(@address_parts, &(address |> Codec.get(&1) |> Codec.string()))
  end

  defp address_values(_address), do: []
end
