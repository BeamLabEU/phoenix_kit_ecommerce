# PR #118 — follow-up

See [CLAUDE_REVIEW.md](CLAUDE_REVIEW.md).

| Finding | Severity | Resolution |
|---|---|---|
| Comment and guide described an unreleased billing | IMPROVEMENT - MEDIUM | Fixed, with a test of the rerun on 0.24.0 and on billing `main` |
| The suite flaked on core 3.3.0 (from `0337d18 libs`) | IMPROVEMENT - MEDIUM | Fixed: `shop_enabled` committed once, serial tests only write it in setup |
| `up/1`'s `@doc` said it applies "nothing later" | NITPICK | Fixed |
| Pins and table ownership had gone stale | NITPICK | Fixed in AGENTS.md, the pin test's comments, the moduledoc and the guide |

## Validation for the 2026-11-05 review batch (#61 – #118)

Run on the final tree, on disposable databases removed afterwards.

- **Full suite, locked deps** (core 3.3.0, billing 0.24.0, catalogue 0.50.0):
  **5,026 tests, 0 failures, 3 skipped, 9 excluded**, seed `212129`;
  `PGPOOL=10 mix test --max-cases 8`.
- **Before the harness fix** the same suite had 1 and then 3 failures, all connection
  timeouts in test setup, on different tests each run.
- **Async modules alone**, after the fix: 686 tests, 0 failures, three runs in a row,
  no timeouts. The async phase fell from about 42s to about 14s.
- **Against billing `main`** (`PHOENIX_KIT_BILLING_PATH`, own build path and database,
  `mix.lock` restored): 79 tests, 0 failures, across
  `online_payment_chain_test.exs`, `checkout_online_payment_test.exs`,
  `online_payment_test.exs` and `migrations_up_version_test.exs`. That includes the
  three real-chain tests the Hex run excludes, so the page update on the new topic
  was exercised through the provider's webhook.
- **`mix precommit`: passed.** Credo found no issues; Dialyzer reports the same eight
  suppressed findings and 15 unnecessary suppressions as before. It ran before the
  last test-harness edit, so format and `credo --strict` were run again on the final
  tree: both clean.
- **Regressions.** The subscription and picker tests failed before their fixes. The
  rerun test passes before and after: it pins a property rather than reproducing a
  defect. The re-read after subscribing has no test.

The gettext references were refreshed with `--no-fuzzy`: 0 new, 0 removed, reference
lines only. No version bump, CHANGELOG entry or release.
