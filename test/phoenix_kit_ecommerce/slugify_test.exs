defmodule PhoenixKitEcommerce.SlugifyTest do
  @moduledoc """
  Slug generation for shop content.

  This rule drifted between Product and Category twice — Cyrillic, then German —
  and each time the fix landed on one schema only, so a title that worked as a
  product silently broke as a category. It now lives in one place for the whole
  ecosystem (`locale_slug`, via `PhoenixKit.Utils.Slug`), so a third drift is not
  reachable: there is no second implementation to drift from.

  ## The behaviour change worth knowing about

  The old `PhoenixKitEcommerce.Slugify` applied German expansion **unconditionally**
  — every language got `ö → oe`. That was the same bug the `slugger` package has:
  correct for German, wrong for Estonian, where `ö` folds to `o`. Expansion is now
  conditional on the language, which is why every case below passes one.

  Plain `ExUnit.Case`, deliberately: these are pure-function cases and need no
  database. Under `DataCase` they would inherit `@moduletag :integration` and be
  skipped on a checkout without PostgreSQL — the regression suite for a bug that has
  recurred twice would be the part that does not run. The schema-parity check, which
  does need a connection, lives in `PhoenixKitEcommerce.SlugifyParityTest`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEcommerce.Product

  describe "German — but only when the text is German" do
    test "expands umlauts and ß for de" do
      # Core used to produce "gro-e-fu-ball": ö decomposes to o, and ß is discarded,
      # leaving the separator behind it.
      assert Product.slugify("Größe Fußball", "de") == "groesse-fussball"
      assert Product.slugify("Öl", "de") == "oel"
      assert Product.slugify("Ähre", "de") == "aehre"
      assert Product.slugify("ÜBER", "de") == "ueber"
    end

    test "does NOT expand for Estonian, which folds the same letters" do
      # The bug the old module had. Estonian ö is its own letter, not a decorated o.
      assert Product.slugify("Töö õun", "et") == "too-oun"
      assert Product.slugify("Öl", "et") == "ol"
    end

    test "with no language, folds rather than expands" do
      # Correct and conservative: a usable slug, just not locale-tuned. Note this
      # DIFFERS from the old module, which expanded for everyone.
      assert Product.slugify("Größe Fußball") == "grosse-fussball"
    end
  end

  describe "Cyrillic" do
    test "transliterates rather than producing an empty slug" do
      # An ASCII-only slugifier stripped every character and stored "" — which
      # callers read as "no slug yet" and regenerated forever.
      assert Product.slugify("Видеопродакшн", "ru") == "videoprodakshn"
      assert Product.slugify("Цветокоррекция", "ru") == "tsvetokorrektsiya"
    end

    test "works with no language too" do
      assert Product.slugify("Видеопродакшн") == "videoprodakshn"
    end
  end

  describe "ordinary input" do
    test "plain ASCII is unchanged" do
      assert Product.slugify("Corporate Video") == "corporate-video"
      assert Product.slugify("Corporate Video", "en") == "corporate-video"
    end

    test "blank and nil are empty, never a crash" do
      assert Product.slugify("") == ""
      assert Product.slugify(nil) == ""
      assert Product.slugify("!!!") == ""
    end
  end

  describe "one implementation, ecosystem-wide" do
    test "Product and Category cannot disagree, because neither owns the rule" do
      # Both now call PhoenixKit.Utils.Slug. This assertion is close to a tautology
      # by construction — which is the point. It used to be the thing that broke.
      for text <- ["Größe Fußball", "Видеопродакшн", "Öl", "Müük"], lang <- ["de", "et", nil] do
        assert Product.slugify(text, lang) == Slug.slugify(text, locale: lang)
      end
    end
  end
end
