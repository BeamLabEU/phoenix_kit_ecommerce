# PR #19 — Delete the duplicate slugifier and slug each language as that language

**Reviewed:** 2026-08-10 · **Author:** mdon · **Verdict:** merged, one alias fix
on `main`. Released in **0.2.0**.

+107 / −129 across 6 files, deleting `lib/phoenix_kit_ecommerce/slugify.ex`
outright. Reviewed as part of the phoenix_kit 2.0 sweep.

## The premise checks out against core 2.0.0

This package carried its own `Slugify` module with a German-expansion table
(`ö` → `oe`, `ß` → `ss`) applied *before* handing off to core, precisely because
core's own rule could not express a locale. Core 2.0.0 removes that reason:
`PhoenixKit.Utils.Slug` now delegates to the
[`locale_slug`](https://hex.pm/packages/locale_slug) package, and `:locale` is
first-class. Verified against the installed core 2.0.0 rather than from the
docs:

| Input | no locale | `locale: "de"` | `locale: "et"` |
|---|---|---|---|
| `Größe Fußball` | `grosse-fussball` | `groesse-fussball` | `grosse-fussball` |
| `Töö õun` | `too-oun` | `toeoe-oun` | `too-oun` |

So `Slug.slugify(text, locale: lang)` genuinely subsumes the local table, and
deleting it removes a real duplicate rather than a safety net. `slugify_parity_test.exs`
is the right thing to keep — it pins that the two agree rather than trusting the
claim.

Worth stating plainly because I got this wrong elsewhere in this sweep: **the
`:locale` option is real in core 2.0** (I initially removed it from
`phoenix_kit_entities` after testing against a core-1.7 checkout, and had to
revert that in entities 0.3.1). This PR's use of it is correct.

## Fixed on `main`

`mix credo --strict` flagged one nested-module reference in
`slugify_test.exs` — `PhoenixKit.Utils.Slug.slugify/2` called fully qualified.
Added the alias.

## Verification

| Check | Result |
|---|---|
| `mix precommit` | **passes** against core 2.0.0, after the alias fix |
| `mix test` | **128 tests, 0 failures** (326 excluded — no Postgres available) |

Sibling pins raised in step: `phoenix_kit_billing` → `~> 0.7`,
`phoenix_kit_ai` (optional) → `~> 0.18`.
