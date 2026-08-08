# Code Review: PR #14 — Put the products and categories list state in the URL

**Reviewed:** 2026-08-05
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/14
**Author:** Timujeen (timujinne)
**Head SHA:** `ce66143c7559e94f0feb1ca71ebbd334523443fb`
**Merge commit:** `62f5162`
**Status:** Merged

## Summary

Adopts core's `PhoenixKitWeb.Live.UrlState` in the two admin list LiveViews
(Products, Categories). Search, filters and page move into the query string,
so a filtered list becomes a shareable, reload-proof URL and Back returns to
the previous query instead of leaving the page.

The adoption itself is correct against the module's contract:

- declared params are assigned by the `on_mount` hook **before** `mount/3`,
  and `mount/3` was correctly stripped of the assigns that would have
  overwritten them;
- the list load moved out of `mount/3` into `handle_url_state/2`, which is
  both the Iron Law fix (`mount/3` runs twice) and what makes one code path
  serve the first render, a shared link and the Back button;
- both LiveViews annotate `@impl` on their callbacks, so they correctly
  define the explicit `handle_params/3` stub the module's docs require
  rather than letting the un-annotated one be injected;
- `replace: true` on the debounced search box and a real history entry for
  the discrete filters is the right split;
- page reset on a filter change is handled by `maybe_reset_page/3` inside
  the module, so dropping the manual `assign(:page, 1)` from every handler
  is correct, not an oversight.

The status whitelists match their schemas exactly:
`~w(active draft archived)` against `Product.@statuses`, `~w(physical
digital)` against `Product.@product_types`, and `~w(active unlisted hidden)`
against `Category.@statuses`.

## Issues Found

### 1. [BUG - HIGH] A non-UUID `?parent=` / `?category=` crashes the list LiveView — FIXED

**File:** `lib/phoenix_kit_ecommerce/web/categories.ex` lines 14-20, 89-91;
`lib/phoenix_kit_ecommerce/web/products.ex` lines 12-19, 104-106
**Confidence:** 95/100

`parent_filter` and `category_filter` are declared with no `:in` whitelist
and no cast, so whatever the query string carries lands in the assign
verbatim. Both then flow straight into an Ecto parameter:

```elixir
defp filter_by_parent_uuid(query, uuid), do: where(query, [c], c.parent_uuid == ^uuid)   # ecommerce.ex:3552
defp filter_by_category(query, uuid),    do: where(query, [p], p.category_uuid == ^uuid)  # ecommerce.ex:3434
```

Both columns are `UUIDv7`, and `Ecto.Type.dump(UUIDv7, "not-a-uuid")` returns
`:error` (verified), which makes `Repo.all/1` raise `Ecto.Query.CastError`.
The raise happens inside `handle_url_state/2` — i.e. inside the
`handle_params` hook — so the LiveView dies: a 500 on the dead render and a
crash-and-reconnect loop once connected. `/admin/shop/categories?parent=x`
is enough.

`parse_category_uuid/1` looked like the guard for this on the products side
but was a pass-through (`def parse_category_uuid(id) when is_binary(id), do: id`),
and in any case only the *event* handler called it — the query string never
went through it.

Severity split by PR:

- **`?parent=` is new attack surface from this PR.** Before it, `parent_filter`
  was set only from the select, whose options are real UUIDs plus the `"root"`
  sentinel; it was never URL-readable.
- **`?category=` predates this PR** — the old `handle_params/3` read
  `params["category"]` through the same pass-through. This PR did not cause
  it, but it does keep it, and it is the same defect.

**Fix applied:** both values are re-parsed in `handle_url_state/2` through
`Ecto.UUID.cast/1`, with `"root"` kept as the one legitimate non-UUID value
on the categories side; anything unparseable falls back to "no filter".
Re-parsing in the callback rather than only in the event handler is what
covers the URL path. A plain `assign/3` on a declared param is explicitly
supported by `UrlState` (the next patch reads its merge base back from the
assigns), so the rejected value is dropped from the URL rather than
resurrected. `filter_parent`'s inline `if(parent == "", ...)` now routes
through the same function.

**Tests added:** `test/phoenix_kit_ecommerce/web/listing_lvs_test.exs` — a
malformed `?category=` and `?parent=` must render the unfiltered list, plus
`?parent=root` to pin that the sentinel still works. ⚠️ These are
`:integration`-tagged (they need PostgreSQL) and were **not** executed in
this review environment, which has no database — see "Verification" below.

### 2. [OBSERVATION] The PR ships no tests

The behaviour change is entirely observable through the URL — a shared link
restores state, a filter change resets the page, Back returns to the previous
query — and none of it is pinned. `listing_lvs_test.exs` already mounts both
LiveViews through the test router, so the cost of a URL-state assertion there
is one line. The two tests added under issue 1 are a start, not coverage of
the feature.

### 3. [NITPICK] The two lists disagree on the search key

Categories publishes `?q=`, Products publishes `?search=`. Products is
constrained — it already published `?search=` links, and changing it would
break them — but `UrlState` supports exactly this case with `alias:`, so
Products could converge on `?q=` while still reading `?search=`. Two admin
lists side by side using different keys for the same control is the kind of
thing that gets copied into the third one.

### 4. [OBSERVATION] `Categories.mount/3` still queries the database

`load_static_category_data/1` (two queries: `list_categories/1` and
`product_counts_by_category/0`) remains in `mount/3`, which runs twice per
page load. The PR moved the *filtered* load out, which is the load that
matters, and moving the static load is not free — `handle_url_state/2` would
re-run it on every keystroke pause, and gating on `connected?/1` leaves the
dead render without `@all_categories`. Left alone deliberately; recorded so
the next person does not read the remaining query as an oversight.

## What Was Done Well

- The comments explain the *why* at each non-obvious point — why `mount/3`
  no longer assigns the params, why the load lives in `handle_url_state/2`,
  why the search box replaces its history entry. These are exactly the three
  things a reader would otherwise get wrong when copying the pattern.
- Reading core's contract properly: the `@impl`-annotated `handle_params/3`
  stub is a subtle requirement buried in the module docs, and getting it
  wrong is a compile warning under `--warnings-as-errors`.
- Net −56 lines while adding shareable URLs: five hand-rolled
  assign-and-reload handlers per LiveView collapse into one-liners.

## Verdict

**Approved with fixes.** The adoption is faithful to core's contract and the
lifecycle reasoning is right. One class of defect got through — a declared
param whose value reaches Ecto unvalidated — which is the cost of moving
state from a select box (whose values you control) to a query string (whose
values you do not). Fixed for both params.

## Verification

- `mix precommit` — see the release commit; run after the fixes.
- ⚠️ `mix test` in this environment ran **111 tests, 0 failures, 238
  excluded**: no PostgreSQL is available here, so every `:integration`-tagged
  test — including the whole of `listing_lvs_test.exs` and therefore both
  tests added above — was auto-excluded and has not been executed. They are
  written against the existing helpers in that file and should be run on a
  machine with a database before being trusted.
