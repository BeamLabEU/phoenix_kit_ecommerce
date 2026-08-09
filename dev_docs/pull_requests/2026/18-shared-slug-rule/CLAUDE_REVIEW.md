# Code Review: PR #18 — Share one slug rule between products and categories, and fix three broken tests

**Reviewed:** 2026-08-09
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/18
**Author:** Max Don (mdon)
**Head SHA:** `189e605935fd821f5379d5e63de0add3f3526fda`
**Merge commit:** `d0ce46b`
**Status:** Merged

## Summary

Small, focused, and correct in its central judgement. Two changes:

1. **One slug rule.** `Product` and `Category` each carried a private
   `slugify/1`. The two drifted twice — Cyrillic, then German — and both times
   the fix reached one schema and not the other, so the same text worked as a
   product and broke as a category. `PhoenixKitEcommerce.Slugify` is now the
   rule; both schemas delegate; a parity test asserts they agree.
2. **Three failing tests** in `checkout_shipping_step_test.exs`, plus a stale
   `glob_ex` lock entry failing `deps.unlock --check-unused`.

The diagnosis in the PR body is the part worth keeping: *"Patching `Category` a
third time would only reset the clock. Two implementations of one rule is the
defect."* That is the right call, the author volunteers that the German
breakage was introduced by their own earlier change, and the module doc records
the history where the next person will read it. This is how a recurrence should
be handled.

## Correcting the record on the three test failures

The PR calls them "three pre-existing failures in the merged tree." They existed
in the merged tree, but they were **not** pre-existing relative to PR #17 —
all three were introduced by `6610836`, the post-merge review commit for PR #17,
which is mine. Measured at PR #17's merge (`80f7537`):

```
$ git show 80f7537:test/.../checkout_shipping_step_test.exs | grep -c back_to_billing
0
# and no test called the shipping_method/1 fixture more than once
```

- The `shipping_method/1` fixture hardcoded `"name" => "Standard"`, and the name
  drives a **unique** slug. Latent until a test needed two methods. My
  country-change regression test is the first that does.
- No test clicked `back_to_billing` until that same test, so the ambiguous
  selector could not fire before it.
- The `id="flash-error"` collision in `test_layouts.ex` needed a flash rendered
  *inside* the LiveView tree. Before `6610836` the invalid-shipping path always
  `push_navigate`d away instead of re-rendering with a flash; my
  `reject_invalid_shipping_selection/1` is what put a flash on an in-tree
  render, colliding with core's `LayoutWrapper` flash.

Root cause on my side: no PostgreSQL in the review environment, so all 323
`:integration` tests — including the four I had just written — were
auto-excluded, and I shipped them unrun. The gate I reported (format, compile,
credo, dialyzer, 120 unit tests) was accurate and insufficient, and I should
have flagged "these specific new tests have never executed" more loudly than a
line at the bottom of the gate table. Max found and fixed all three against a
real database. Recorded here rather than quietly corrected because the failure
mode — a reviewer who cannot run the tier they are adding tests to — will recur.

## Verification

**The three test fixes are all correct.**

- Uniquifying the fixture name is the right fix, not `on_conflict` or a shared
  method: the collision is real domain behaviour (slug uniqueness), and the
  test should stop depending on there being only one method in the world.
- The flash-id namespacing reasoning is exactly right, and the comment points at
  the corroborating evidence (`root.html.heex` carries no flash for the same
  reason). Nothing else referenced the old ids — `rg` confirms.
- `glob_ex` **is** genuinely unused here. It is required by `igniter` and
  `rewrite`, but neither is in this project's resolved tree (`mix deps.tree`
  shows neither; `deps/glob_ex` is a leftover directory from an earlier
  resolve). Re-ran `mix deps.get` after the removal: the lock is unchanged, so
  the entry does not come back. `mix credo --strict` still runs clean, which was
  the risk worth checking.

**The delegation is clean.** `defdelegate` on `Product` (which needs the public
arity for `AITranslatable.slug_base/3`) and a private one-liner on `Category`.
No behaviour change to either schema beyond the German rule now applying to
categories, which is the stated intent.

**Slug generation is write-once.** Both `maybe_generate_slug/1` implementations
only fill a language whose slug is `nil` or `""`. So this PR cannot rewrite an
existing URL — it only affects content created from now on. That matters for
issue 1 below and is worth stating explicitly, because "we changed the slug
rule" usually implies a migration and here it does not.

## Issues Found

### 1. [BUG - MEDIUM] The German table breaks every other language that uses ä/ö/ü — ACKNOWLEDGED, NOT FIXED
**File:** `lib/phoenix_kit_ecommerce/slugify.ex`
**Confidence:** 100/100 (measured)

The moduledoc states core's NFD pass "strips the umlaut and drops ß outright."
Only the second half is true. Measured against `PhoenixKit.Utils.Slug.slugify/2`
at the pinned version:

| input | core alone | `PhoenixKitEcommerce.Slugify` |
|---|---|---|
| `Größe Fußball` | `gro-e-fu-ball` | `groesse-fussball` |
| `Öl` | `ol` | `oel` |
| `Ähre` | `ahre` | `aehre` |
| `Müük` (et) | **`muuk`** | **`mueuek`** |
| `Tänav` (et) | **`tanav`** | **`taenav`** |
| `Jõgi` (et) | `jogi` | `jogi` |
| `Видеопродакшн` | `videoprodakshn` | `videoprodakshn` |

Core transliterates `ä/ö/ü` to `a/o/u` correctly on its own. The single
character it genuinely mishandles is `ß`, which it drops and leaves the
separator behind (`Fußball` → `fu-ball`). So six of the table's eight entries
are unnecessary, and they are the six that change other languages' output.

`et` is one of this module's three shipped catalogues, so this is not
theoretical. PR #17 introduced it on products; this PR extended it to
categories — the widening is a side effect of the consolidation, not a
regression the consolidation caused, but it is a widening.

The language code is available at both call sites — `maybe_generate_slug/1`
reduces over `{lang, title}` in both schemas, and `AITranslatable.slug_base/3`
has `target_lang` — so scoping the table to `de*` would need no new plumbing.

**Deliberately not fixed.** Reported to the developer, who is looking into it;
the decision on 2026-08-09 was to leave the merged behaviour in place rather
than have review reverse a choice two contributors made on purpose. Pinned
instead by tests in `slugify_test.exs` ("the German table is not
language-scoped") so the behaviour is visible and any future change is a
deliberate edit rather than a surprise diff.

### 2. [BUG - MEDIUM] The slug regression suite does not run without PostgreSQL — FIXED
**File:** `test/phoenix_kit_ecommerce/slugify_test.exs`
**Confidence:** 100/100

`use PhoenixKitEcommerce.DataCase` for the whole module, because the parity
check runs `Category.changeset/2` and needs a connection. But `DataCase` sets
`@moduletag :integration`, and the harness auto-excludes that tier when no
database is reachable:

```
$ mix test test/phoenix_kit_ecommerce/slugify_test.exs
0 tests, 0 failures (6 excluded)
```

So on any checkout without Postgres — which per AGENTS.md is an explicitly
supported state, and is the state this review ran in — **none** of the
regression tests for the bug that has now recurred twice execute. Six of them
are pure function calls that need nothing.

**Fix applied.** Split: `SlugifyTest` is plain `ExUnit.Case, async: true` for
the pure cases; `SlugifyParityTest` keeps `DataCase` for the schema-parity
check that genuinely needs a connection. Locally this took the no-database run
from 120 to 127 passing tests.

### 3. [BUG - LOW] The parity test compares a function to a changeset — FIXED
**File:** `test/phoenix_kit_ecommerce/slugify_test.exs`
**Confidence:** 85/100

```elixir
product_slug = Product.slugify(title)          # raw function
category_slug = %Category{} |> Category.changeset(...) |> get_change(:slug)
```

Asymmetric. `Product.slugify/1` and `Category`'s private `slugify/1` are now
both one-line delegates to the same module, so comparing them proves little;
what drifted was what each *schema* does when deriving a slug. As written, if
`Product.maybe_generate_slug/1` stopped calling `slugify/1`, or started
post-processing (truncation, a uniqueness suffix — `AITranslatable` already
does both for its own path), the test would still pass while the schemas
disagreed in production.

**Fix applied.** `SlugifyParityTest` drives **both** sides through their
changeset, and adds a second assertion pinning the Cyrillic drift's actual
symptom — a non-empty title must never yield an empty slug — which the
equality check alone would miss if both schemas broke the same way.

### 4. [NITPICK] The disambiguating selector is a translated string — FIXED
**File:** `test/phoenix_kit_ecommerce/web/checkout_shipping_step_test.exs:221`

```elixir
element("button[phx-click='back_to_billing']", "Change")
```

`"Change"` is `gettext("Change")` in the markup. The suite is not pinned to an
English content locale, and this module's own AGENTS.md documents a whole class
of bugs from assuming it is. Also the comment says three buttons carry the
event; on the review step there are two (the billing card's pencil and the
footer arrow) — the third, `#checkout-shipping-back`, only renders on the
shipping step.

**Fix applied.** Gave the review-step button `id="checkout-review-change-billing"`
and targeted the id, which is stable under translation and under a fourth
button being added.

### 5. [NITPICK] Orphan comment left behind in `product.ex` — FIXED

Removing the German block left the preceding comment describing a Cyrillic fix
that now lives in another module, terminated by a bare `#` line above the
`@doc`. Rewritten to say the one thing still true of that line: it is public
for the AI adapter, and the rule lives in `Slugify`.

### 6. [OBSERVATION] No CHANGELOG entry

Stated as deliberate ("No version bump or CHANGELOG entry — left at 0.1.16"),
and skipping the *version bump* is right — nothing is released. But the PR does
change user-visible behaviour: German category names slug differently than they
did yesterday. `## Unreleased` already exists and already carries PR #17's work
and its post-merge fixes, so there was a section to add to at no cost. Entry
added.

## What Was Done Well

- **Named the real defect.** "Two implementations of one rule" rather than
  "German categories are broken." A third point-fix was the tempting move and
  would have set up drift number three.
- **Owned the regression.** "my change is what put them there," in the PR body,
  where reviewers read it.
- **Wrote the test that would have caught both.** The parity idea is right even
  though its execution needed the two fixes above; the concept is what stops
  recurrence.
- **The flash-id diagnosis.** Duplicate DOM ids aborting a LiveView test is not
  an obvious failure mode, and the fix generalises (namespaced test ids) rather
  than deleting the offending element.
- **Checked the lock claim rather than asserting it.** `deps.unlock
  --check-unused` is the kind of thing usually left broken for months.

## Gate

Run at `HEAD` after the fixes above:

| Step | Result |
|---|---|
| `mix format --check-formatted` | clean |
| `mix compile --warnings-as-errors` | clean |
| `mix credo --strict` | no issues |
| `mix dialyzer` | passed |
| `mix test` | **127** tests, 0 failures (was 120 — the split freed 7) |
| `mix deps.unlock --check-unused` | clean |
| `mix deps.get` | lock unchanged (the `glob_ex` removal sticks) |

⚠️ **Still no PostgreSQL in this environment.** 325 `:integration` tests remain
auto-excluded, including `SlugifyParityTest` and the checkout tests this PR
repaired. The author reports 449/0 against a live database on the merged tree;
the three fixes above are additive to that run and have not themselves been
executed against a database. **They need a DB run before release** — that is the
exact gap that produced issue 2's failures last time, and asserting otherwise
would repeat it.

## Verdict

**Approved with fixes.** The consolidation is the right response to a
twice-recurring drift, the test repairs are correct and were genuinely needed,
and the `glob_ex` removal checks out under `deps.get`. The two substantive
findings are both about the safety net rather than the change: the regression
suite was gated behind a database it did not need (issue 2), and the parity
assertion was weaker than it looked (issue 3) — together they meant the test
written to prevent drift number three would not have run on a fresh checkout
and would not have caught a schema-level divergence if it had.

Issue 1 stands open by decision, with the measurements recorded above and the
behaviour pinned by test so it cannot drift again unnoticed while it is being
looked into.
