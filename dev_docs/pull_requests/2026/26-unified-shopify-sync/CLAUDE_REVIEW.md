# Code Review: PR #26 — Unified Shopify sync: field-grouped diff, word-level text diff, keyless price fallback

**Reviewed:** 2026-09-02
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/26
**Author:** Tymofii Shapovalov (timujeen)
**Head SHA:** 8cb45b71b6edf75fea07f958a02af9cb9b60fef4 (squash-merged onto `main`)
**Status:** Merged

## Summary

Rewrites the Shopify sync page and the layer beneath it:

- **`Shopify.TextDiff`** (new) — word-level diff over `List.myers_difference/2`
  on whitespace-preserving tokens, so rejoining fragments reproduces both
  inputs exactly. No diff dependency added.
- **`Shopify.StorefrontClient`** (new) — keyless price fallback reading the
  public `/products.json`, deliberately trimmed to `"handle"`/`"variants"`,
  with its own 429/`Retry-After` handling, a page cap and a wall-clock
  deadline.
- **`Shopify.Source`** (new) — pure `decide/2` + I/O `fetch/2` split that
  falls back to the storefront only on a *credential* failure
  (`:unauthorized`/`:forbidden`/`:missing_credentials`) and aborts on
  anything transient, so a rate limit can never be reported as "no text
  changes".
- **`ProductDiff`** — gains `opts[:only]` (validated, no `:all` sentinel) so
  a narrow source can't have its absent fields read as deletions, plus
  `matched_count/3` and `base_locale` on the `Change` struct.
- **`Web.ShopifySync`** — field-grouped sections, 25-row pagination,
  request→confirm modal on every write path, bulk selection scoped to one
  section's current page, and a storefront-fallback banner.

`AdminClient` gains one line: 403 → `{:error, :forbidden}`.

## Issues Found

### 1. [BUG - MEDIUM] `:forbidden` — the one error atom this PR introduced — has no `format_error/1` clause — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/shopify_sync.ex:979-1012`
**Confidence:** 100/100

The PR added `{:ok, %{status: 403}} -> {:error, :forbidden}` to
`AdminClient`, made `:forbidden` a first-class member of `Source`'s
`@credential_errors`, and gave it a `format_fallback_reason/1` clause
("the access token is missing the required scope"). The sibling list —
`format_error/1`, which renders the banner when the sync *aborts* — never
grew the matching clause, so `:forbidden` fell through to:

```elixir
defp format_error(reason) do
  gettext("Could not reach Shopify: %{reason}", reason: inspect(reason))
end
```

The reachable path is `{:fallback_failed, :forbidden, storefront_reason}`
— a 403 token plus an unpublished or password-protected storefront, which
`Source`'s own moduledoc calls "an ordinary pairing". That tuple exists
*specifically* to lead with the actionable credential half, and it was
rendering `Could not reach Shopify: :forbidden. The storefront fallback
also failed: ...` — a raw atom, in the exact slot the design says must
carry the operator's next action. The correct wording was already written
30 lines away in `format_fallback_reason/1`; the two lists simply drifted.

Added `format_error(:forbidden)` naming the missing `read_products` scope,
plus a LiveView test driving a 403 + failed-fallback through the real
transport stub that asserts both the scope name's presence and the raw
atom's absence.

### 2. [BUG - MEDIUM] 84 new msgids were never extracted — the whole page renders English on every non-English install — FIXED
**File:** `priv/gettext/*/LC_MESSAGES/default.po`, `priv/gettext/default.pot`
**Confidence:** 100/100

AGENTS.md is explicit: a `gettext("…")` added anywhere under `web/` lands
in *this* module's catalogue and needs `mix gettext.extract && mix
gettext.merge priv/gettext --no-fuzzy` here. This PR added ~40 new
`gettext`/`ngettext` calls to the rewritten LiveView and none were
extracted. Running the extractor on the merged tree produced **84 new
msgids across 5 catalogues, 0 removed** — the entire Shopify Sync page
plus `Provider`'s setup instructions (some of the latter predating this
PR, from #23).

The consequence lands squarely on the four catalogues that were at 0
untranslated before this: a de/fr/ru/et operator got a fully translated
admin UI everywhere *except* this page, which rendered in English.

Nothing could have caught it. A missing `msgstr` falls back to the msgid,
and the msgid **is** the English source string, so the page looks correct
in the only locale the suite renders in — the failure is invisible by
construction from inside a test that asserts on English output.

Fixed: extracted, merged, and translated all 84 into `de`/`fr`/`ru`/`et`
(`en` left with empty msgstrs, which is how it is shipped by design).
Verified: 0 empty msgstr and 0 interpolation-token mismatches in all four,
and a second `gettext.merge` is a zero-change no-op. Added
`i18n_test.exs` cases asserting the property the four catalogues actually
hold — every msgid translated — so an un-run extraction fails the suite
instead of shipping.

### 3. [BUG - MEDIUM] Section headers and field names render in English regardless of locale — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/shopify_sync.ex:74-104, 814-815`
**Confidence:** 100/100

Independent of #2, and not fixable by extraction. Both label sets lived as
string literals inside module attributes:

```elixir
@sections [{:price, "Prices"}, {:title, "Titles"}, ...]
@field_labels %{title: "Title", body_html: "HTML text", ...}
defp section_label(field), do: Map.fetch!(@section_labels, field)
```

A module attribute holds a compile-time literal that `mix gettext.extract`
never sees, and `gettext/1` refuses a runtime variable as its key — so
there was no way to translate them *from where they were stored*. The
template renders `{section.label}` straight into the DOM, and
`field_label/1`'s output is interpolated into eight gettext'd sentences as
`%{field}`. A German operator saw `Prices` as a header and
`%{count} Price-Änderungen von Shopify anwenden?` in the confirm modal.

Unlike PR #25's storefront filter labels, these are module-owned constants,
not admin data — there is no collision risk and no reason not to translate
them unconditionally.

Fixed: `@sections` reduced to an ordering list, and `section_label/1` /
`field_label/1` rewritten as one `gettext/1` call per field so the literals
are extractable. `section_label/1` keeps its crash-on-unknown-field
behaviour deliberately (a silent English fallback would hide a section
added to `@sections` without a header). English output is byte-identical,
so the existing assertions on `"HTML texts"` / `"Prices"` still hold.

**Limitation left on record.** `%{field}` is a bare noun interpolated into
a whole sentence, so a translator sees the noun and the sentence
separately — the exact shape `PhoenixKitEcommerce.Vocabulary` exists to
avoid on the storefront, where each noun needs its own complete literal. A
locale that inflects gets the nominative in a slot the sentence may want in
another case. Accepted here: this is the admin surface, and the alternative
is seven full sentence variants for each of eight strings. A comment on
`field_label/1` says not to copy the shape to a customer-facing page.

### 4. [IMPROVEMENT - MEDIUM] `render/1` dereferences `@modal` but guards on `@pending` — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/shopify_sync.ex` (confirm modal, end of `render/1`)
**Confidence:** 90/100

```heex
<.confirm_modal :if={@pending} ... title={@modal.title} ... />
```

`pending_modal/1`'s `:row` clause returns `nil` when the pending change is
no longer in `@changes`, and its `Map.fetch!(change.changes, field)` raises
if the change survives but that field doesn't. Both are unreachable today
— every path that mutates `@changes` (`confirm_*`, `bump_page`, `"check"`)
also clears `@pending` — so this is a latent invariant, not a live bug. But
the failure mode is a `render/1` crash that takes the LiveView process
down, and gating on the value actually dereferenced costs nothing.
Changed to `:if={@modal}`.

### 5. [IMPROVEMENT - LOW] The row-apply path skipped the source-visibility guard its two siblings have — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/shopify_sync.ex` (`request_apply_row/`,`confirm_row_apply/3`)
**Confidence:** 85/100

`visible_changes/2`'s own `@doc false` note argues at length that filtering
a bulk write by `field_visible?/2` is a second, independent guard worth
keeping even though a real `check → render` flow structurally cannot
produce a `:storefront` change carrying a non-price field — and
`visible_field_changes/3`'s note extends that to "Apply section" and
"Apply selection" because `Map.has_key?(&1.changes, field)` alone doesn't
know `field` is hidden for the current source.

A single row's apply is the third way into a write and was the one path
still checking `Map.has_key?` directly. Routed both its request and confirm
handlers through `visible_field_changes/3`, so all three agree.

### 6. [OBSERVATION] `AdminClient.retry_after_seconds/1` is unclamped, unlike its `StorefrontClient` twin — FIXED
**File:** `lib/phoenix_kit_ecommerce/shopify/admin_client.ex:110-126`
**Confidence:** 90/100

`StorefrontClient` got a careful clamp and a moduledoc paragraph on why:
an unclamped negative `Retry-After` makes `Process.sleep/1` raise
`FunctionClauseError` straight out of a function whose spec promises
`{:ok, _} | {:error, _}`, and a huge one sleeps for real. Its Admin
sibling runs the identical `Process.sleep(:timer.seconds(parsed_header))`
with neither a clamp nor the deadline the storefront path has.

Shopify's own `Retry-After` is well-behaved, so this is not a live bug —
but the header still crosses the network, and an asymmetry like this
outlives the reason for it. Applied the same `max(0) |> min(60)` clamp and
pinned it with a real-fetch test that returns `retry-after: -1` on a 429
(the clamp is private here, so it is asserted through the fetch rather
than directly).

### 7. [OBSERVATION] `mount/3` queries the database — NOT FIXED, pre-existing and out of scope
**File:** `lib/phoenix_kit_ecommerce/web/shopify_sync.ex:134-152`
**Confidence:** 100/100

`assign(:connection, shopify_connection())` runs
`Integrations.list_connections/2` in `mount/3`, which LiveView calls twice
(dead render + WebSocket connect). It belongs in `handle_params/3`. Not
introduced here — it is verbatim from #23 — and it is one indexed read on
an admin page, so the cost is negligible and moving it would change the
dead-render output the current tests assert on. Recorded, not changed.

### 8. [NITPICK] `TextDiff`'s moduledoc says "Both functions are pure", then documents that both emit telemetry
**File:** `lib/phoenix_kit_ecommerce/shopify/text_diff.ex`
**Confidence:** 100/100

Emitting a `:telemetry` event is a side effect. The doc is otherwise
unusually careful (it corrects its own earlier claim that `summary/2` was
cheap, with measured numbers). Left alone. Relatedly, `:telemetry` is
called directly but is not a declared dependency — it resolves as a
non-optional transitive of both `ecto_sql` and `phoenix`, so it always
loads, but a library calling into it should declare it. Not added: a
dependency change is the maintainer's call, not a review's.

## What Was Done Well

- **`Source.decide/2`'s fallback rule is right, and the reasoning is on
  record.** Falling back to a price-only source on a *transient* Admin
  failure would report "no text changes" when the truth is "we could not
  check" — a silent-wrong-answer failure mode in a sync tool. Restricting
  the fallback to credential errors and aborting on everything else is the
  correct discrimination, and I cross-checked the `@credential_errors`
  whitelist against every error `AdminClient` can actually emit
  (`:shop_not_found`, `:rate_limited`, `{:unexpected_status, _}`, Req
  transport errors): none of the excluded ones should fall back.
- **`ProductDiff`'s `opts[:only]` fails in the safe direction, on purpose.**
  `Keyword.validate!` rejects a typo'd *option*, and `validate_only!/1`
  rejects a typo'd *field atom* — the latter because `only: [:titel]` would
  otherwise compare nothing and report a catalog "in sync" that was never
  checked. That is the failure mode worth raising on, and the doc says so.
- **`base_locale` moved onto the `Change` struct.** A change diffed against
  one locale must be applied into that same locale; re-reading
  `Translations.default_language()` at apply time was a real latent bug.
- **`@doc false`-public functions with a stated reason.** `visible_changes/2`,
  `visible_field_changes/3`, `coverage_percent/2` and
  `StorefrontClient.retry_after_seconds/1` are all public solely so a
  synthetic-input unit test can reach a branch no end-to-end flow can
  produce. `visible_changes/2`'s doc even records that an earlier version
  filtered changes without *trimming* their field maps and passed 634 tests
  while doing so. That is the right lesson, written down at the right place.
- **`@per_page` is justified as correctness, not polish**, with the measured
  12 ms/row number behind it, and the template carries a comment explaining
  why `<.accordion>` cannot be used here without reinstating the freeze.
- **`TextDiff`'s round-trip property plus the separate tokenizer test.** The
  PR noticed that the round-trip table can *never* catch a `trim:` flip
  (both variants rejoin correctly) and added a test on the flip itself
  after finding it changed real output on 304 of ~4010 sampled inputs.
- **Pagination reads the clamped current page, not the raw stored one**, with
  the 51-row repro pinned — a subtle off-by-one that only shows up after an
  apply shrinks a section.

## Verdict

**Approved with fixes.** The domain layer is careful work, and the design
notes in it are unusually good — several of them record a real bug the
author hit and the reason the obvious test could not have caught it.

The three MEDIUM findings are all the same shape, and it is the shape this
PR's own comments warn about: *two lists that must agree, where the drift
is invisible in English.* `:forbidden` reached one error-formatting list
and not its sibling; 84 msgids reached the source and not the catalogues;
seven section labels reached the DOM without reaching Gettext at all. Each
one renders correct-looking English while being wrong in every other
locale, which is why 662 passing tests said nothing about any of them. All
three are fixed, with regression tests that fail on English-only output.
