# PR #120 — Reprice a catalogue-backed shop

Reviewed Tymofii Shapovalov’s [PR #120](https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/120) at `d356afb` against `main` at `dbdf431`.

## BUG - HIGH — A concurrent edit could change how a surcharge is priced

The initial scan checked each override against the global and category options. The write used a fresh item but skipped that check and retained the global options read before the options writer lock. An intervening edit could introduce a conflicting override or change a fixed option to a percentage. The repricer could then commit an ambiguous item or scale a percentage as money.

## BUG - MEDIUM — Prices could commit after the rebuild request failed

The reprice helper discarded the error returned by `Search.Jobs.enqueue_rebuild/1`. A direct caller could see success while searches still used old-base prices until another rebuild. The billing callback also depends on the repricer returning errors so it can roll back the currency switch.

See [the follow-up](FOLLOW_UP.md) for the fixes and regression coverage.
