defmodule PhoenixKitEcommerce.Shipping.ShipmentRequest do
  @moduledoc """
  A request to register one shipment with the carrier
  (`PhoenixKitEcommerce.Shipping.Provider.create_shipment/2`).

    * `order_uuid` / `reference` - the order and its number
    * `service` - the service key of the order
    * `country` - ISO 3166-1 alpha-2 code of the destination country, or `nil`
    * `destination` - where the parcels go
    * `parcels` - what is sent
    * `recipient` - `%{name, company, email, phone, raw_phone}` from the
      order's frozen `billing_snapshot` (as the admin may have corrected it):
      `name` is the person, `company` the company of a company buyer (else
      `nil`); `phone` is in E.164 (`e164_phone/2`) or `nil`, `raw_phone` is
      the number as it was typed, for an adapter that normalises it its own
      way
    * `idempotency_key` - unique to this attempt of this shipment: send it
      where the carrier's API takes one, so a request the network repeated is
      not registered twice. A retry of a failed shipment is a new attempt
      with a new key
    * `payer` - `:shop`, or `:recipient` when the order is paid to the
      carrier on delivery (`metadata["shipping_pay_on_delivery"]`)
    * `description` - the goods, from the order lines, at most 100 characters
    * `declared_value` / `currency` - the total of the order's goods lines, in
      the order's currency
    * `cod_amount` / `cod_currency` - cash on delivery; always `nil` for now

  There is no sender: the adapter fills it from its own settings and returns
  what it used in `ShipmentResult.extra`.
  """

  alias PhoenixKit.Utils.CountryData
  alias PhoenixKitEcommerce.Shipping.{Codec, Destination, Parcel}

  @payers [:shop, :recipient]
  @description_max 100
  # Countries whose leading 0 is part of the number, not a trunk prefix.
  @keeps_leading_zero ~w(IT SM VA)

  defstruct order_uuid: nil,
            reference: nil,
            service: nil,
            country: nil,
            destination: %Destination{},
            parcels: [],
            recipient: %{name: nil, company: nil, email: nil, phone: nil, raw_phone: nil},
            idempotency_key: nil,
            payer: :shop,
            description: nil,
            declared_value: Decimal.new(0),
            currency: nil,
            cod_amount: nil,
            cod_currency: nil

  @type recipient :: %{
          name: String.t() | nil,
          company: String.t() | nil,
          email: String.t() | nil,
          phone: String.t() | nil,
          raw_phone: String.t() | nil
        }

  @type t :: %__MODULE__{
          order_uuid: String.t() | nil,
          reference: String.t() | nil,
          service: String.t() | nil,
          country: String.t() | nil,
          destination: Destination.t(),
          parcels: [Parcel.t()],
          recipient: recipient(),
          idempotency_key: String.t() | nil,
          payer: :shop | :recipient,
          description: String.t() | nil,
          declared_value: Decimal.t(),
          currency: String.t() | nil,
          cod_amount: Decimal.t() | nil,
          cod_currency: String.t() | nil
        }

  @doc "Serialises the request into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request), do: Codec.encode(request)

  @doc "Builds a request from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = request), do: request

  def from_map(map) when is_map(map) do
    %__MODULE__{
      order_uuid: map |> Codec.get(:order_uuid) |> Codec.string(),
      reference: map |> Codec.get(:reference) |> Codec.string(),
      service: map |> Codec.get(:service) |> Codec.string(),
      country: map |> Codec.get(:country) |> Codec.country(),
      destination:
        map |> Codec.get(:destination) |> Codec.struct_from(Destination) || %Destination{},
      parcels: map |> Codec.get(:parcels) |> Codec.list(&Codec.struct_from(&1, Parcel)),
      recipient: map |> Codec.get(:recipient) |> recipient(),
      idempotency_key: map |> Codec.get(:idempotency_key) |> Codec.string(),
      payer: map |> Codec.get(:payer) |> Codec.atom(@payers) || :shop,
      description: map |> Codec.get(:description) |> Codec.string() |> description(),
      declared_value: map |> Codec.get(:declared_value) |> Codec.decimal() || Decimal.new(0),
      currency: map |> Codec.get(:currency) |> Codec.string(),
      cod_amount: map |> Codec.get(:cod_amount) |> Codec.decimal(),
      cod_currency: map |> Codec.get(:cod_currency) |> Codec.string()
    }
  end

  def from_map(_other), do: nil

  @doc """
  The recipient part of a request from a map with string or atom keys
  (`name`, `company`, `email`, `phone`, `raw_phone`). Blank values become
  `nil`; the
  phones are kept as given (see `e164_phone/2`).
  """
  @spec recipient(term()) :: recipient()
  def recipient(map) when is_map(map) do
    %{
      name: map |> Codec.get(:name) |> present(),
      company: map |> Codec.get(:company) |> present(),
      email: map |> Codec.get(:email) |> present(),
      phone: map |> Codec.get(:phone) |> present(),
      raw_phone: map |> Codec.get(:raw_phone) |> present()
    }
  end

  def recipient(_other), do: %{name: nil, company: nil, email: nil, phone: nil, raw_phone: nil}

  @doc "Cuts a description to #{@description_max} characters; blank becomes `nil`."
  @spec description(term()) :: String.t() | nil
  def description(text) when is_binary(text) do
    case text |> String.trim() |> String.slice(0, @description_max) do
      "" -> nil
      cut -> cut
    end
  end

  def description(_other), do: nil

  @doc """
  A phone number in E.164 (`+` and 8 to 15 digits), or `nil`.

  An `(0)` (the trunk prefix written next to a country code) is dropped, then
  spaces, dashes, dots and brackets. A number that starts with `+` or `00`
  already has its country code. Any other number takes the calling code of
  `country` (ISO 3166-1 alpha-2) in place of one leading trunk `0`:
  `"5555 1234"` for `"EE"` is `"+37255551234"`, `"067 123 45 67"` for `"UA"`
  is `"+380671234567"`. Italy, San Marino and the Vatican keep the leading
  `0`, which is part of their numbers. `nil` when there is no number, the
  number has other characters, or it has no country code and `country` gives
  none.
  """
  @spec e164_phone(term(), term()) :: String.t() | nil
  def e164_phone(phone, country) when is_binary(phone) do
    compact =
      phone
      |> String.replace(~r/\(\s*0\s*\)/u, "")
      |> String.replace(~r/[\s\-\.\(\)\/]/u, "")

    digits =
      case compact do
        "+" <> rest ->
          rest

        "00" <> rest ->
          rest

        local ->
          with code when is_binary(code) <- calling_code(country),
               do: code <> national(local, Codec.country(country))
      end

    if is_binary(digits) and Regex.match?(~r/\A[1-9]\d{7,14}\z/, digits), do: "+" <> digits
  end

  def e164_phone(_phone, _country), do: nil

  defp national("0" <> rest, country) when country not in @keeps_leading_zero, do: rest
  defp national(local, _country), do: local

  defp calling_code(country) do
    case country |> Codec.country() |> CountryData.get_country() do
      %{country_code: code} when is_binary(code) and code != "" -> code
      _ -> nil
    end
  end

  defp present(value) do
    case Codec.string(value) do
      nil -> nil
      text -> if String.trim(text) == "", do: nil, else: String.trim(text)
    end
  end
end
