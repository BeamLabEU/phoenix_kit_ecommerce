# PR #120 follow-up

- Re-read enabled global options after acquiring the options writer lock. Check the item’s catalogue and validate its overrides again under its row lock. Two PostgreSQL regression tests change an override or the global option type after the initial scan and check the refusal or the preserved percentage.
- Return a tagged error when Oban refuses the search rebuild. A PostgreSQL regression test refuses the job insert and checks that the stored item retains its original price and currency. The error message is translated for all supported locales.
- Removed the unused `ex_aws_ec2` entry left in the lockfile by the dependency upgrade on `main`. The precommit gate checks for unused lock entries.
- Removed an unreachable refusal for a hypothetical third product source. Dialyzer confirmed that both possible return values of `ProductSource.current/0` were already handled.

The full suite reported 5,254 tests, zero failures and four exclusions. The final focused run passed all 114 tests. The final `mix precommit` passed, and a separate host without Catalogue compiled and returned `:ok` from the legacy capability check.

## Release-range review

**BUG - MEDIUM** — A malformed `price_modifiers` array raised during the initial scan, and a boolean `ecommerce` value could be overwritten as if it were missing. The locked write now refuses both with the item UUID and `:malformed_ecommerce_data`. Regression tests verify that the earlier item and shipping price roll back and no rebuild job survives.
