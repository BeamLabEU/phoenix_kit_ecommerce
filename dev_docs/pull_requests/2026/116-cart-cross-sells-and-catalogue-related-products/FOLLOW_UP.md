# PR #116 follow-up

Both findings in [CODEX_REVIEW.md](CODEX_REVIEW.md) are addressed:

- Cross-sell Add reloads the originating cart's offers, including current
  visibility, availability and quick-add eligibility. Deleted products and
  withdrawn offers are ignored; newly configurable products get a View link.
- Both `add_to_cart` paths lock and reload the active cart before changing
  its lines. A checkout that wins the lock causes a rollback, including when
  the caller's cart struct still says active.

Ten new regressions cover five stale-offer cases, catalogue category visibility,
and four tests of simple/selected-option adds against converted carts. Nine
were exercised before their fixes and failed; the catalogue visibility case
adds coverage of the same refresh through the optional source.

Validation with locked Hex dependencies (core 3.0.0, billing 0.24.0,
catalogue 0.50.0):

- Focused suite: **63 tests, zero failures**.
- Full suite: **5,021 tests, zero failures, three skipped, nine excluded**,
  seed `633527`; `PGPOOL=12 mix test --max-cases 8`.
- `mix format`, `git diff --check` and `mix precommit`: **passed**. The gate
  includes warnings-as-errors compilation, unused-lock checking, Hex audit,
  formatting, strict Credo and Dialyzer. No suppressions changed; Dialyzer
  reports the existing eight suppressed findings and 15 unnecessary suppressions.

The exclusions select unavailable dependency variants and analytics, including
the real payment chain unavailable in locked billing. The same three existing
phone-component compatibility cases remain skipped as in the #114/#115 reviews.

Integration checks use the disposable database
`ecommerce_pr116_review_20261029`. The race fixtures clean up their committed
carts/products and restore the shop setting. The database is removed after
validation; pre-existing databases are unchanged. No release or dependency change.

## Claude review, 2026-11-05

See [CLAUDE_REVIEW.md](CLAUDE_REVIEW.md).

| Finding | Severity | Resolution |
|---|---|---|
| Catalogue picker offered deleted items and showed raw statuses | BUG - MEDIUM | Fixed: `exclude_deleted: true`, label through `StatusLabels.product/1` |
| The product page never passes `language:` | NITPICK | Left open: no visible effect |
| `RelatedPicker` events are not permission-gated | NITPICK | Left open: it stages inputs and writes nothing |

Validation is recorded in [the #118 follow-up](../118-fresh-core-3x-chain/FOLLOW_UP.md),
which covers the whole review batch.
