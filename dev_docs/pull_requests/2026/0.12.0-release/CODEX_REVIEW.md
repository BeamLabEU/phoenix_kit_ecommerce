# 0.12.0 release review

- Reviewer: Codex
- Date: 2026-11-15
- Baseline: Hex `0.11.0`, published 2026-11-11; matching Git tag `0.11.0`
- Reviewed head: `0180b35` plus the fixes recorded below
- Verdict: ready for release after these fixes; no unresolved release blockers found

## Scope

Reviewed the complete `0.11.0..0180b35` change, including the core 3.5.0 floor
and shim removal, refund stock handling, low-stock notifications, product-page
stock display, settings authorization, translations, dependency lock and test
harness changes. Rechecked the earlier refund-race finding and its follow-up
against Billing's event worker and Warehouse's posting implementation.

Hex still lists `0.11.0` as its latest release. Main already declares `0.12.0`
and has its changelog entry. No version bump, publish or tag is part of this review.

## Findings

### BUG - HIGH: a host without the optional AI package cannot compile the product form

`lib/phoenix_kit_ecommerce/web/product_form.ex` wrapped
`use PhoenixKitAI.Components.AITranslate.Embed` in `if @ai_translate?`, but
Elixir expands the `use` macro even when that branch is false. A consumer that
omits the optional package fails with `module ...AITranslate.Embed is not loaded
and could not be found`.

This predates the release diff (the same code is in `0.11.0`). It is included
here because the release promises that hosts without optional integrations
compile and run. The ordinary suite resolves all the optional packages and
therefore did not catch it.

**Fixed:** evaluate the quoted AI setup only when the package is present. The
authorization hook remains before Embed's hook. Added
`product_form_optional_ai_test.exs`, which compiles the real form under a
separate module name against a missing AI namespace, even when the test build
has AI installed. It verifies that the ordinary form exists and the AI
translation callback is absent.

Also reproduced the failure in an isolated checkout with the four optional
direct dependencies removed, then verified that the fixed source compiles
there with warnings treated as errors. A runtime smoke check confirms that
AI, Catalogue, Entities and Warehouse are absent, Legacy availability works,
and refund lookup without Warehouse returns `nil`.

### IMPROVEMENT - MEDIUM: the engineering guide described the old supported core and exclusions

`dev_docs/guides/engineering-reference.md` still promised core
`>= 2.65.0` and described the old-core API, canonical URL, MCP and i18n test
exclusions removed by this release. That gives maintainers incorrect dependency
and validation instructions.

**Fixed:** document core `>= 3.5.0 and < 4.0.0`, the remaining dependency-specific
exclusions, and the deferred expansion required for the optional AI Embed.

## Verified release behavior

- The new direct core calls exist in the locked core 3.5.0. The compound
  requirement preserves support for later core 3.x minors.
- Billing's durable worker reads the current order before delivery. A refund
  committed while a paid delivery posts stock is handled by the paid
  delivery's final read. Short-stock marks and refund notifications commit
  together under the order lock.
- Refund receipts use the sale's location, quantities and order reference.
  Warehouse 0.7.0 serializes the external reference and returns the existing
  posted receipt on a retry. The unique-conflict fallback is also harmless.
- Low-stock checks sum quantities across warehouses and the source conversion
  combines multiple order lines of one item. The notification actions are
  registered in the stock notification type.
- Product-page stock changes re-read the canonical product. Threshold zero
  suppresses the count; zero stock disables the button. Context stock checks
  still enforce additions independently of the button.
- New settings events recheck `manage_settings`, log successful changes, and
  use wrappers whose invalid/read-error defaults are notify and threshold zero.
- New gettext messages and plural forms are present in all six catalogues;
  no fuzzy entries were introduced. No migration changed.

## Validation

- Full `mix test` on the reviewed head: **5,205 tests, 0 failures, 4 excluded**.
  Excluded tags: `:old_catalogue`, `:no_catalogue`, `:analytics`; Warehouse and
  Catalogue integration suites ran.
- After the form fix: product-form and authorization suites, including the new
  absent-AI compilation regression: **38 tests, 0 failures**.
- Isolated build without AI, Warehouse, Catalogue or Entities:
  `mix compile --no-deps-check --warnings-as-errors` and runtime smoke checks
  passed. Only dependency removal was applied to the isolated mix project;
  repository requirements and lock were unchanged.
- `mix precommit`: compilation with warnings as errors, unused-lock check,
  Hex audit, format check, strict Credo and Dialyzer passed. Dialyzer reported
  eight existing suppressions and no unsuppressed errors.

## Limits and release notes

Low-stock notifications remain best-effort and can duplicate or miss a crossing
under concurrent stock changes; this is already documented. Nothing reserves
stock in carts or unpaid orders. There was no browser pass against a running
host app; storefront rendering and live updates were exercised by LiveView tests.

Hosts must use core 3.5.0 or newer. No shop migration is required. New settings
default to notifying on refunds and hiding the remaining-stock count.
