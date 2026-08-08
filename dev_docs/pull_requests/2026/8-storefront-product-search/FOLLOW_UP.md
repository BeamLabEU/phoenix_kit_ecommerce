# PR #8 follow-up — Add storefront product search (name, SKU, tags)

Triaged 2026-08-04 during the ecommerce quality sweep. Both findings in
`CLAUDE_REVIEW.md` re-verified against current code.

## Fixed (pre-existing)

- ~~**#1 [BUG - MEDIUM] `merge_missing_builtin_filters/1` position collides with existing filters**~~ — fixed in the PR itself; the built-in `search` filter no longer loses a position tie against a saved filter.

## Skipped (with rationale)

- **#2 [OBSERVATION] Admin filters table doesn't reflect `"position"` order** (`web/settings.ex`). Confirmed still true: the Settings page renders `@storefront_filters` in raw list order while the storefront renders position-sorted. The reviewer rated this 70/100 confidence and explicitly out of scope, and it predates the PR — `add_metadata_filter` already appended to the raw list.

  Left alone deliberately: it is a display-ordering inconsistency on an admin table, with no correctness consequence for the storefront, and the fix belongs with a wider pass over that settings page rather than bolted onto a search PR. Recorded here so it is findable rather than lost.

## Files touched

None in this follow-up — both findings were already resolved or deliberately out of scope.

## Verification

`mix precommit` exit 0. Suite: 245 tests, 0 failures via `PHOENIX_KIT_PATH=../phoenix_kit mix test`.

## Open

None.
