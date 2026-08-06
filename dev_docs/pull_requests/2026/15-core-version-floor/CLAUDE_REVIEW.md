# Code Review: PR #15 — Raise the core floor to 1.7.231, the release that ships UrlState

**Reviewed:** 2026-08-06
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/15
**Author:** Timujeen (timujinne)
**Head SHA:** `6887ba64a995e87dbd5292464c09e4b7e5f5d427`
**Merge commit:** `522392c`
**Status:** Merged

## Summary

One line of `mix.exs`: `pk_dep(:phoenix_kit, "~> 1.7.214")` →
`"~> 1.7.231"`. `Web.Products` and `Web.Categories` `use
PhoenixKitWeb.Live.UrlState` (adopted in PR #14), which first shipped in core
1.7.231, so the declared requirement permitted a core without that module.
`mix.lock` already carried 1.7.231; the PR corrects the published contract,
not the current build.

The claim is correct in every particular, and I verified it two ways rather
than one.

## Verification

**The version is right, and off by one in neither direction.** Core's
CHANGELOG lists `PhoenixKitWeb.Live.UrlState` under `## 1.7.231 - 2026-08-05`
(#680) — the PR's own point that 1.7.230 would reproduce the defect holds:
the module merged while core's `mix.exs` still read 1.7.230.

Rather than trust the changelog, I built the package against each release
using the `PHOENIX_KIT_PATH` mechanism AGENTS.md documents, with core fetched
from Hex:

| Core | `mix compile --force --warnings-as-errors` |
|---|---|
| 1.7.231 (the new floor) | clean |
| 1.7.230 (one below) | `CompileError` — *module PhoenixKitWeb.Live.UrlState is not loaded* at `web/categories.ex:14` **and** `web/products.ex:12` |

So the floor is necessary. It is also *sufficient*: every `PhoenixKit.*` /
`PhoenixKitWeb.*` module this package references resolves in the 1.7.231
tree (the only misses are the `PhoenixKit.Modules.Shop*` names, which are
this module's own `compat/shop.ex` shims), and nothing added in 1.7.232 —
impersonation entry points, `MultiSession.role_label/1` — is used here.

**It agrees with the other core-version constraint in the codebase.**
`@payment_option_version 162` (`lib/phoenix_kit_ecommerce.ex:3175`) guards
order inserts against a host that has not migrated to core V162, and V162
ships in 1.7.231 as well. Its runtime accessor,
`PhoenixKit.Migrations.Postgres.migrated_version_runtime/1`, is present in
1.7.231. The two constraints now name the same release instead of
disagreeing by 17 versions.

**Scope discipline is correct.** `@version` and `CHANGELOG.md` are
maintainer-owned in this workspace and were left untouched, as the PR body
states.

## Issues Found

### 1. [BUG - HIGH] The sibling floor `phoenix_kit_billing "~> 0.1"` has the identical defect, and a worse one — FIXED

**File:** `mix.exs` line 119 (pre-fix)
**Confidence:** 95/100

The PR fixed the core floor and stopped. The billing floor in the very next
dep entry is stale in exactly the same way, and by a much wider margin —
`~> 0.1` admits everything from 0.1.0 up to 0.9.x, while the code has been
written against 0.5.x. I fetched every published billing release and checked
the surface this package actually calls:

| Billing | What breaks |
|---|---|
| 0.1.0 | The `PhoenixKitBilling` namespace **does not exist** — the package was still `PhoenixKit.Modules.Billing`. Every one of this module's ~16 `PhoenixKitBilling.*` call sites is undefined. |
| 0.1.1 – 0.1.2 | No `tax_enabled?/0`, `get_tax_rate/0`, `get_tax_rate_percent/0` — the tax path in `lib/phoenix_kit_ecommerce.ex:3813-3849`. |
| 0.1.3 – 0.5.1 | Compiles, then fails silently: `PhoenixKitBilling.Order` has no `payment_option_uuid` field before 0.5.2. |

The last row is the interesting one, and it is the failure mode this
codebase has already been bitten by. `maybe_put_payment_option/2`
(`lib/phoenix_kit_ecommerce.ex:3157`) writes `"payment_option_uuid"` into the
order attrs once the host is migrated past core V162 — and `cast/3` drops a
key the schema does not declare, without an error. The comment above it
reads "the schema always carries the field once billing is updated", which
is true of 0.5.2+ and was never enforced by the requirement. A consumer
resolving billing 0.5.1 with core 1.7.231 gets orders that record the
payment option only in metadata, with nothing anywhere saying so.

**Fix applied:** floor raised to `~> 0.5.2`, with the reasoning in the dep
comment. No `mix.lock` change — the lock is already at 0.5.3.

### 2. [IMPROVEMENT - MEDIUM] Nothing in the suite could have caught either floor — FIXED

**File:** `test/phoenix_kit_ecommerce/dependency_floor_test.exs` (new)
**Confidence:** 90/100

A too-low floor is structurally invisible here: `mix.lock` pins the newest
of everything, so the build that proves the package is the one build that
can never resolve an old dep. Both defects had to be found by reading.

Added a DB-free contract test pinning the four symbols the floors exist to
guarantee — `PhoenixKitWeb.Live.UrlState` (and its `__using__`),
`migrated_version_runtime/1`, `Order.payment_option_uuid`, and the billing
tax trio. It asserts against the *resolved* dependency, so it fails wherever
a resolution actually lands below the floor: a host's build, or a
`<APP>_PATH` checkout pointed at an older tree. It is not a restatement of
`mix.exs` — deleting the requirement would not fail it; resolving billing
0.5.1 would.

### 3. [NITPICK] The dep comment counts files instead of naming them — not fixed

**File:** `mix.exs` lines 109-112

"which 2 LiveView files in this module `use`" is a number that goes stale
the moment a third list screen adopts `UrlState`, and a wrong count in a
comment is worse than no count. Naming `web/products.ex` and
`web/categories.ex` would not drift silently. Left alone: the comment is
otherwise accurate and rewriting a correct comment to churn the same line
the PR just touched is not worth the diff.

## What Was Done Well

- **The PR body does the work a reviewer would otherwise have to do**, and
  does it honestly: it states that `~> 1.7.189` *does* permit 1.7.232 and
  that this workspace's host is unaffected, rather than overselling the
  severity. It then names the precise consumer configuration that breaks.
- **The off-by-one is called out explicitly** — why 1.7.231 and not
  1.7.230, with the mechanism (the module merged before the version bump).
  That is the exact error this class of fix usually makes.
- **Both failure modes are named**, and they are genuinely different: a
  compile error from source, an `UndefinedFunctionError` on `on_mount/4`
  from a precompiled artefact, because the `on_mount({:url_state, cfg})`
  tuple is baked into the `.beam`.
- **The comment explains the constraint, not the change** — it says which
  module is needed and what happens without it, matching the existing
  1.7.214 note's style.
- **Correct restraint on `mix.lock` and `@version`.**

## Verdict

**Approved with fixes.** The change is correct, minimal, and better argued
than most one-line PRs; I confirmed it by compiling against both 1.7.230 and
1.7.231. The only real criticism is one of scope — the dep list contained a
second, wider instance of the same defect two lines below the one that was
fixed, which is now closed along with a regression test that fails if either
floor slips again.
