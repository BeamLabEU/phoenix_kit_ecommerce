# Code Review: PR #28 — Stop the mount-time snapshot overwriting default-language edits

**Reviewed:** 2026-09-05
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/28
**Author:** Tymofii Shapovalov (timujeen)
**Head SHA:** ad10b9c56f5830c752cec7431a0281df0caec505
**Status:** Merged

## Summary

`TranslationTabs.merge_translations_to_attrs/5` wrote the main form's
default-language value first and then reduced over `translations_map` — the
snapshot `build_translations_map/2` took at **mount** — which also carries the
default language. Step 2 therefore put the mount-time text straight back over
the edit from step 1, so correcting a default-language field that was non-empty
when the page loaded was silently discarded (issue #27). A field that was empty
at mount has no snapshot entry, so its edit landed, which is why the defect read
as "creating works, correcting does not".

The fix rejects the default language from that reduce. The premise checks out:
`translation_fields/1` renders an informational alert instead of inputs when
`is_default_language` is true (both admin forms pass
`@current_translation_language == @default_language`), so the snapshot's
default-language entry can never be refreshed from the UI and has nothing to
contribute. The main form is its only source.

Tests are well chosen — both the non-empty and the empty-at-mount halves are
pinned, plus an over-correction guard that a fix dropping the whole snapshot
would fail.

## Issues Found

### 1. [BUG - CRITICAL] Saving a product now wipes the default language's `body_html`, `seo_title` and `seo_description` — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/product_form.ex` lines 2349-2360 (pre-fix), `lib/phoenix_kit_ecommerce/web/components/translation_tabs.ex` lines 445-455 (pre-fix)
**Confidence:** 100/100 — reproduced against the merged code

`build_localized_params/4` hands `merge_translations_to_attrs/5` a
`default_values` map with **six hardcoded keys**:

```elixir
default_values = %{
  "title" => params["title"],
  "slug" => params["slug"],
  "description" => params["description"],
  "body_html" => params["body_html"],           # no main-form input
  "seo_title" => params["seo_title"],           # no main-form input
  "seo_description" => params["seo_description"] # no main-form input
}
```

The product form only renders main-field inputs for `title` (line 846), `slug`
(line 888) and `description` (line 933). `body_html`, `seo_title` and
`seo_description` exist **only** inside the translation tabs, so `params` never
carries them and those three keys arrive with the value `nil`.

`merge_field_value/4` matched `nil` against its `{:ok, _empty_value}` clause and
**deleted** the language's entry. Before this PR that deletion was invisible:
the very reduce the PR removed put the snapshot's default-language value back.
With the default language now (correctly) excluded, nothing restores it.

Reproduced against the merged tree with the exact params shape the form
submits:

```
merged attrs: %{
  title: %{"en" => "Wooden Vase"},
  body_html: %{},          # was %{"en" => "<p>Long imported Shopify body</p>"}
  seo_title: %{},          # was %{"en" => "Buy Wooden Vase"}
  seo_description: %{},    # was %{"en" => "Nice"}
  ...
}
```

Impact: every save from the admin product form — including an unrelated price or
status edit — silently destroyed the default language's HTML body and both SEO
fields. Shopify-imported catalogues carry `body_html` on essentially every
product, so this is data loss on the most common admin action, and the same
"save reported success" symptom as the bug the PR set out to fix.

**Fix applied** (two layers, both small):

1. `merge_field_value/4` now treats `{:ok, nil}` as *not submitted* and returns
   the accumulator untouched. A rendered input always posts a string — `""` when
   the user empties it — so `nil` can only mean "the form has no such field".
   `""` still deletes, so clearing a field the form *does* render still works.
2. `build_localized_params/4` in **both** forms now builds `default_values` with
   `Map.take(params, Enum.map(translatable_fields, &to_string/1))`, so the map
   reflects what the submission actually carried and stays correct as fields are
   added or removed. (The category form's three fields all have main-form
   inputs, so it was not affected — the same latent trap is closed there too.)

A regression test pins the nil case in
`test/phoenix_kit_ecommerce/translation_tabs_test.exs`.

### 2. [OBSERVATION] The snapshot's default-language entry is now dead weight

`build_translations_map/2` still collects the default language, and both forms
still keep it in `@product_translations` / `@category_translations`, but
`merge_translations_to_attrs/5` now ignores it. That is harmless — the tabs read
the same assign to decide tab completeness badges (`calculate_status/3`), which
legitimately wants the default language — but it means the snapshot is no longer
a merge input for that language. Worth remembering if a future change makes the
default-language tab editable: it would need the main form's inputs updated, not
the snapshot's.

## What Was Done Well

- The commit message and the in-code comment both explain *why* the empty-field
  case masked the bug. That is the hard half of the diagnosis and it is now on
  record where the next reader will hit it.
- `Enum.reject/2` before the reduce is the minimal correct narrowing — the
  tempting over-correction (skip the snapshot entirely) would have dropped every
  other language, and the test suite explicitly guards against it.
- The premise was verified rather than assumed: the default-language tab really
  does render an alert instead of inputs, in both admin forms.

## Verdict

**Approved with fixes.** The diagnosis and the change itself are correct, but the
narrowing exposed a latent `nil`-means-cleared bug in the caller that turned a
silent-edit-loss defect into silent-content-loss on every product save. Fixed
here with a regression test.
