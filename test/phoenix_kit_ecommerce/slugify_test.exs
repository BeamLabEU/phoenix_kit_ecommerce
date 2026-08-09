defmodule PhoenixKitEcommerce.SlugifyTest do
  @moduledoc """
  This rule has drifted between Product and Category twice — Cyrillic, then
  German — and each time the fix landed on one schema only, so a title that
  worked as a product silently broke as a category.

  Plain `ExUnit.Case`, deliberately: `Slugify.slugify/1` is a pure function
  and these cases need no database. Under `DataCase` they inherited its
  `@moduletag :integration` and were skipped entirely on a checkout without
  PostgreSQL — the regression suite for the bug that has recurred twice was
  the part that did not run. The schema-parity check, which does need a
  connection, lives in `PhoenixKitEcommerce.SlugifyParityTest`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Slugify

  describe "German" do
    test "expands ß rather than dropping it to a separator" do
      # Core turns "Größe Fußball" into "gro-e-fu-ball": ö decomposes to o,
      # and ß is discarded, leaving the separator behind it.
      assert Slugify.slugify("Größe Fußball") == "groesse-fussball"
    end

    test "handles uppercase forms, which appear before core lowercases" do
      assert Slugify.slugify("Öl") == "oel"
      assert Slugify.slugify("Ähre") == "aehre"
      assert Slugify.slugify("ÜBER") == "ueber"
    end
  end

  describe "Cyrillic" do
    test "transliterates rather than producing an empty slug" do
      # An ASCII-only slugifier stripped every character and stored "".
      assert Slugify.slugify("Видеопродакшн") == "videoprodakshn"
      assert Slugify.slugify("Цветокоррекция") == "tsvetokorrektsiya"
    end
  end

  describe "ordinary input" do
    test "lowercases and hyphenates" do
      assert Slugify.slugify("Corporate Video") == "corporate-video"
    end

    test "non-binary input yields an empty slug rather than raising" do
      assert Slugify.slugify(nil) == ""
      assert Slugify.slugify(42) == ""
    end
  end

  describe "the German table is not language-scoped" do
    # Pinning the KNOWN limitation, not endorsing it. `ä/ö/ü` are expanded
    # for every language, but core already transliterates them correctly on
    # its own (`Müük` -> `muuk`, `Tänav` -> `tanav`); only `ß` genuinely
    # needs the pre-pass. So Estonian — one of this module's three shipped
    # locales — slugs with doubled vowels.
    #
    # Left as-is by decision (2026-08-09); reported upstream. This test is
    # here so the behaviour is visible and a future fix is a deliberate
    # edit rather than a surprise.
    test "Estonian titles get the German expansion too" do
      assert Slugify.slugify("Müük") == "mueuek"
      assert Slugify.slugify("Tänav") == "taenav"
    end

    test "characters core already handles well are unaffected" do
      # õ is not in the table, so Estonian gets core's correct answer here.
      assert Slugify.slugify("Jõgi") == "jogi"
    end
  end
end
