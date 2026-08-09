defmodule PhoenixKitEcommerce.Slugify do
  @moduledoc """
  The one slug generator for shop content.

  ## Why this module exists

  Products and categories slugged their titles with two separate private
  implementations, and the two drifted twice — in opposite directions, and each
  time the same way: whatever was fixed on `Product` was not fixed on
  `Category`, so a title that worked as a product silently broke as a category.

    1. **Cyrillic.** `Category` kept an ASCII-only slugifier (`\\w` without the
       `u` flag matches no Cyrillic), so a Russian-only name stored an EMPTY
       slug and the category had no URL. `Product` had already been moved onto
       core's transliterating slugifier.
    2. **German.** Moving `Category` onto core's slugifier fixed Cyrillic and
       inherited a different bug: core's NFD pass strips the umlaut and drops ß
       outright, so "Größe Fußball" became "gro-e-fu-ball". That was fixed on
       `Product` — and not on `Category`.

  Two implementations of one rule is the defect; a third fix applied to both
  files would only reset the clock. This module is the rule, and both schemas
  delegate to it.

  ## German before core

  The expansion runs BEFORE `Slug.slugify/2` because core's normalisation is
  lossy for exactly these characters: it decomposes `ö` to `o` and discards `ß`.
  German orthography expands them instead (`oe`, `ss`), so the mapping has to
  happen while the original character is still there.
  """

  alias PhoenixKit.Utils.Slug

  # Applied before the core pass. Uppercase forms are included because a title
  # is not lowercased until core runs, so "Öl" must map before that happens.
  @german %{
    "ä" => "ae",
    "ö" => "oe",
    "ü" => "ue",
    "Ä" => "Ae",
    "Ö" => "Oe",
    "Ü" => "Ue",
    "ß" => "ss",
    "ẞ" => "Ss"
  }

  @doc """
  Slugifies one piece of text.

  Returns `""` for anything that is not a binary, so a missing translation
  yields an empty slug rather than raising — callers treat empty as "no slug in
  this language".
  """
  def slugify(text) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.map_join("", &Map.get(@german, &1, &1))
    |> Slug.slugify(transliterate: true)
  end

  def slugify(_), do: ""
end
