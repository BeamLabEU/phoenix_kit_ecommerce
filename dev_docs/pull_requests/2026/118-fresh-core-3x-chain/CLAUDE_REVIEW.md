# PR #118 — Fix the ecommerce chain on a fresh core 3.x database

- **Author:** Max Don (mdon)
- **Merged:** 2026-11-05, `bf6546a`
- **Reviewer:** Claude, 2026-11-05, against `main` at `0337d18`

## What was checked

- **The cause is real.** V2 adds `fk_shop_carts_payment_option_uuid`, core 3.x does
  not create `phoenix_kit_payment_options`, and a host's older migration files can
  run this chain first.
- **The call works on the locked billing.** `PhoenixKitBilling.Migrations.up/1` takes
  `prefix:`, is queued through the same `execute/1` as this chain, so order holds,
  and billing is a required dependency. Its V6 creates the table on 0.24.0, which is
  also the floor.
- **`up_statements/2` stays this chain's SQL only**, so the migration digests and the
  test harness (which runs each chain itself) are unaffected.
- **No other cross-chain reference.** No other `phoenix_kit_*` module calls a sibling's
  `up/1`, and this chain's only foreign key into billing is that one.

## Findings

### IMPROVEMENT - MEDIUM — the comment and the guide described a billing that is not released (fixed)

The comment in `up/1` and the guide said billing's `up/1` "leaves a database already
at or past its target as it is". Hex 0.24.0, the locked release and the floor, has no
such guard: `up/1` is unconditional, so every run of this chain re-applies billing's
chain and stamps its current version. The guard exists only on billing's `main`
(`ceec8ed`, whose `mix.exs` also still says 0.24.0, which makes the two easy to
confuse).

Nothing breaks, and that was worth proving rather than assuming. Every statement is
idempotent, the seeds sit behind `to_regclass(...) IS NULL`, and the V2 `UPDATE` only
touches duplicate defaults. On 0.24.0 a host's older billing file can lower the marker
after this chain raised it, until the host's next file raises it again; the tables
stay as they are.

The comment and the guide now state what happens on each billing. A new test deletes
a seeded payment option and runs the chain again, pinning the property the rerun
depends on. It passes on 0.24.0 and on billing `main`, so no floor change is needed.

### IMPROVEMENT - MEDIUM — the suite flaked on core 3.3.0 (fixed; not from this PR)

Recorded here because it is the same move to core 3.x: it came from `0337d18 libs`,
which took the lock from core 3.0.0 to 3.3.0, right after this merge. Two full runs
failed on different tests each time (one, then three): `query_canceled` or
`tcp recv: closed`, all in `DataCase` setup, in tests as plain as a changeset check.
It looks like the shared Postgres; it is not.

Core now reads a setting's row `FOR UPDATE` on every write
(`History.lock_current/1`, unconditionally, even for an unchanged value), and
`DataCase` and `LiveCase` wrote `shop_enabled` in every test's setup. A sandbox holds
its transaction until the test ends, so the async tests queued on that one row, and
whichever waited past the 15s limit was dropped (`timed out because it queued and
checked out the connection for longer than 15000ms`).

`test_helper.exs` now commits the value once, and only serial tests write it in
setup, as before. Tests that flip it themselves still roll back. The 686 tests of the
44 async modules passed three times in a row with no timeouts, and the async phase
fell from about 42s to about 14s, which confirms they were queueing.

### NITPICK — `up/1`'s `@doc` said it applies "nothing later" (fixed)

A pinned `up(version: N)` now also brings billing to billing's current version, which
the `@doc` did not mention. Added a sentence.

### NITPICK — pins and table ownership had gone stale before this PR (fixed)

Found while checking the floors. AGENTS.md still gave core `>= 2.43.0 and < 3.0.0`,
billing `~> 0.20`, AI `~> 0.24` and Warehouse `~> 0.5`, and said core owns the ten shop
tables; `mix.exs` has said otherwise since 0.8.0. The moduledoc of
`core_pin_conformance_test.exs`, the migration moduledoc and the guide's V1 paragraph
had the same drift. All corrected. Comments and docs only: the pin test's assertions
were already right.

Validation is in [FOLLOW_UP.md](FOLLOW_UP.md).
