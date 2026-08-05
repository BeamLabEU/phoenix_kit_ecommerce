defmodule PhoenixKitEcommerce.PriceDisplay do
  @moduledoc """
  How a price is written on the storefront: `From €40.00 /hour`.

  Two independent decorations, both optional and both off by default:

    * a **unit** — free text per language (`"per hour"`, `"/m²"`, `"в час"`),
      so a service shop can state its pricing model. Free text rather than a
      vocabulary: nothing here needs to know what an hour is, and every shop
      invents units the next one has never heard of.

    * a **"From" prefix** — set explicitly by the admin, or implied when the
      product's options genuinely produce a price range.

  ## Storage

  Both live under one reserved key in `Product.metadata`:

      %{"_price_display" => %{
          "unit" => %{"en" => "per hour", "ru" => "в час"},
          "from" => true
        }}

  A single versioned namespace rather than two loose top-level keys: the
  metadata map is an advertised extension point, so this module's data
  stays in one place that can grow (and be recognised) without colliding
  with whatever a host already stores there. `_`-prefixed matches the
  existing `_option_values` / `_price_modifiers` convention, and option
  keys may not begin with `_`, so no user-defined option can shadow it.

  ## Context is load-bearing

  `render/4` takes a context because the same product means different
  things on different pages:

    * `:catalog` — the product's *asking* price. May show "From", and the
      amount comes from the product's option-aware range.
    * `:selected` — the price for the options the shopper picked. Exact, so
      never "From"; keeps the unit.
    * `:cart` / `:order` — a SNAPSHOT of what was (or will be) charged.
      Exact, never "From", and the unit comes from the snapshot rather than
      the live product, so an edit or deletion cannot rewrite a line the
      customer already agreed to.

  Absent data renders exactly what the module rendered before this existed.
  """

  # Backend form (not the runtime `Gettext.dgettext/3` call) so "From" is
  # extractable into this module's own catalogue.
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Web.Helpers

  @key "_price_display"

  @doc """
  The reserved metadata key. Consumers that copy metadata around (the CSV
  upsert, the product form) use this to preserve the namespace.
  """
  def metadata_key, do: @key

  @doc """
  Reads the display settings out of a product (or a raw metadata map).

  Returns `%{unit: %{lang => text}, from: boolean}` with safe defaults.
  """
  def settings(%Product{metadata: metadata}), do: settings(metadata)

  def settings(metadata) when is_map(metadata) do
    raw = Map.get(metadata, @key) || %{}

    %{
      unit: normalize_unit(Map.get(raw, "unit")),
      from: Map.get(raw, "from") == true
    }
  end

  def settings(_), do: %{unit: %{}, from: false}

  @doc """
  Builds the storable namespace map from admin form input.

  Blank units are dropped so an untouched form does not persist empty
  strings, and values are length-bounded — this text renders next to a
  price on a public page, it is not a description field.
  """
  def build(unit_map, from?) do
    unit = normalize_unit(unit_map)

    if unit == %{} and from? != true do
      %{}
    else
      %{"unit" => unit, "from" => from? == true}
    end
  end

  @doc """
  The unit text for a language, with default-language fallback.

  Returns nil when the product has no unit — callers render the plain price.
  """
  def unit_for(product_or_metadata, language) do
    %{unit: unit} = settings(product_or_metadata)

    cond do
      unit == %{} ->
        nil

      is_binary(language) and is_binary(unit[language]) ->
        unit[language]

      true ->
        default = Translations.default_language()
        unit[default] || unit |> Map.values() |> List.first()
    end
  end

  @doc """
  Renders a price for display.

  ## Options

    * `:amount` — the exact amount to render (required for `:selected`,
      `:cart` and `:order`; ignored for `:catalog`, which derives the
      product's range).
    * `:unit` — an explicit unit string, used by snapshot contexts so a
      cart line can render the unit it stored rather than the live one.
    * `:language` — the viewer's language, for unit resolution.
    * `:range_style` — `:from` (default) or `:range`, catalog only.
  """
  def render(product, currency, ctx, opts \\ [])

  def render(%Product{} = product, currency, :catalog, opts) do
    language = Keyword.get(opts, :language)
    %{from: force_from} = settings(product)
    {min_price, max_price} = PhoenixKitEcommerce.get_price_range(product)

    base =
      cond do
        Decimal.compare(min_price, max_price) != :eq and
            Keyword.get(opts, :range_style, :from) == :range ->
          "#{Helpers.format_price(min_price, currency)} - #{Helpers.format_price(max_price, currency)}"

        Decimal.compare(min_price, max_price) != :eq or force_from ->
          # A real option range implies "From" regardless of the flag; the
          # flag additionally forces it for a single-price product (a
          # service quoted "from" a starting rate).
          "#{from_label()} #{Helpers.format_price(min_price, currency)}"

        true ->
          Helpers.format_price(min_price, currency)
      end

    append_unit(base, unit_for(product, language))
  end

  def render(product_or_nil, currency, ctx, opts) when ctx in [:selected, :cart, :order] do
    amount = Keyword.get(opts, :amount)

    unit =
      case Keyword.fetch(opts, :unit) do
        # Snapshot contexts pass their stored unit explicitly — including
        # an explicit nil, which means "this line stored no unit" and must
        # NOT fall back to the live product.
        {:ok, stored} -> stored
        :error -> product_or_nil && unit_for(product_or_nil, Keyword.get(opts, :language))
      end

    Helpers.format_price(amount, currency) |> append_unit(unit)
  end

  defp append_unit(price, nil), do: price
  defp append_unit(price, ""), do: price
  defp append_unit(price, unit), do: "#{price} #{unit}"

  # Gettext-backed so a shop's own catalogue can translate it; the module
  # backend is injected into web/, and this module is context-side.
  defp from_label, do: gettext("From")

  defp normalize_unit(unit) when is_map(unit) do
    unit
    |> Enum.filter(fn {lang, text} -> is_binary(lang) and is_binary(text) and text != "" end)
    |> Enum.map(fn {lang, text} -> {lang, text |> String.trim() |> String.slice(0, 32)} end)
    |> Enum.reject(fn {_lang, text} -> text == "" end)
    |> Map.new()
  end

  defp normalize_unit(_), do: %{}
end
