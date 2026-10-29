# PR #112 — review follow-up

Both findings in `CODEX_REVIEW.md` are fixed, with regression coverage.

Validation on the locked Hex dependencies (core 3.0.0, billing 0.24.0):

- Both new defect regressions failed against the merged code before fixes:
  a boolean phone persisted on an order, and the recovered form lacked the
  phone error after the requirement changed during review.
- Focused checkout and Shopify tests: **81 tests, zero failures, three
  compatibility cases skipped**.
- Final `PGPOOL=12 mix test --max-cases 8`, using an isolated test database,
  seed `639813`: **4,863 tests, zero failures, three skipped, six excluded**.
  The skips select billing's unavailable `require_phone` component support;
  the exclusions select incompatible dependency variants and absent analytics.
- `mix format` and `mix precommit`: **passed**, including warnings-as-errors
  compilation, lock checks, Hex audit, format checking, strict Credo, and
  Dialyzer. Existing Dialyzer suppressions are unchanged (eight warnings
  suppressed, 15 unnecessary suppressions reported).
- The full merged baseline also passed before fixes: 4,860 tests, zero
  failures, three skipped, six excluded, seed `274635`.

The default pre-existing database was at core V224, below core 3.0's V225
migration floor. Integration validation therefore used a fresh database;
the existing database was preserved.

An existing Shopify regression test also hit its one-second `Task.await/2`
limit under concurrent compilation. Replaced that timing assertion with a
first-page assertion in the request stub and an exact malformed-body result.
If pagination resumes, its next request fails immediately; scheduler delays
no longer decide whether this test passes. No Shopify production code changed.
