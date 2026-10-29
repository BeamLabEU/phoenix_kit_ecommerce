# PR #114 follow-up

All four findings in [CODEX_REVIEW.md](CODEX_REVIEW.md) are fixed. Added eight
regression tests covering payment-option snapshots in both edit directions,
duplicate delivery, atomic rollback, the stored checkout language and its
eventual notification link, and the immediate confirmations on older billing
and free orders. Existing checkout coverage now checks the persisted payment
type and default language.

Validation on the final code:

- Full suite with locked Hex dependencies (core 3.0.0, billing 0.24.0):
  **4,923 tests, zero failures, three skipped, nine excluded**, seed `764692`.
- Focused payment and notification tests with locked Hex dependencies:
  **81 tests, zero failures**, seed `138509`.
- Focused tests with the local billing checkout, including its real Stripe
  handoff, taxed total, webhook, live confirmation update and session reuse:
  **62 tests, zero failures**, seed `93997`.
- Full suite with local billing commit `04353c5`, which includes merged
  billing PR #64 (`start_order_payment/2`), and all other dependencies locked:
  **4,926 tests, zero failures, six excluded**, seed `282115`.
- `mix format` and final `mix precommit`: **passed**. The gate includes
  warnings-as-errors compilation, unused-lock checking, Hex audit, formatting,
  strict Credo and Dialyzer. No suppression changes; Dialyzer reports the
  existing eight suppressed findings and 15 unnecessary suppressions.

Full suites use `PGPOOL=12 mix test --max-cases 8`. Both database builds are
isolated from the pre-existing database, which remains below core 3.0's
migration floor. The local billing check runs in a separate temporary source
copy and database; the committed dependency requirements and lock are unchanged.

The locked billing is Hex 0.24.0 and does not export `start_order_payment/2`;
the local checkout still declares 0.24.0 but includes that API. On Hex the
three real-chain tests are compatibility-excluded, while the local build
executes them. The remaining six exclusions select unavailable dependency
variants/analytics. The locked billing also skips three phone-component
compatibility cases; the local checkout supplies that component API.

No version bump, CHANGELOG entry or release.
