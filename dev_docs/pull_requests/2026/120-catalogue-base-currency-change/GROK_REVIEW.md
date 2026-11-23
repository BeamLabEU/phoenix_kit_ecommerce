# PR #120 — Reprice a catalogue-backed shop on a base-currency change

**Reviewed:** 2026-11-23
**Reviewer:** Grok
**Range:** Hex `0.12.0` (`8309cb3`) through `2463131` (the catalogue leg and
its follow-ups; [#120](https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/120)
merged in `9475b05`)
**Head at review:** `2463131`

## Summary

`reprice_for_base_change/3` now reprices the shop's own catalogue beside the
legacy tables, queues one search rebuild inside the change's transaction, and
treats a multiplier of 1 as a relabel. The defects found on the first reviews
are already fixed on main: a concurrent surcharge type or override is refused
under the item lock, a refused rebuild rolls the change back, a malformed
`price_modifiers` list or a non-map `ecommerce` value is
`{:catalogue_item_reprice_failed, uuid, :malformed_ecommerce_data}`, and the
rebase multiplier is taken from the locked row. See `CODEX_REVIEW.md` and
`FOLLOW_UP.md`.

No new defect in this pass.

## Checked, left as they are

- **Late pass.** Items and categories created after the worklist are selected
  with `uuid not in ^seen` and, for items, `data #>> '{ecommerce,currency}'
  IS DISTINCT FROM` the new code. An empty `seen` list compiles to `NOT
  (false)` in the Postgres adapter, so the first late pass still matches.
  A concurrent insert labels the old currency while the base change is
  uncommitted, and the late pass picks it up. A row already labelled with the
  new code is skipped. One late pass, not a loop: a row created after it is
  the window the operation documents.
- **`data_owned_paths: []`.** Catalogue treats an empty owned-path list as
  owning nothing and applies the update to the locked fresh row. A
  `base_price`-only write does not replace `data`.
- **Boolean `ecommerce`.** `write_repriced_item/2` matches a map. `false` and
  `true` fail that match and refuse. A boolean `data` document is not a map
  the schema writes; `false || %{}` would treat a raw-SQL `false` as empty.
  That row is not reachable through the catalogue API. Left.
- **Category `option_schema`.** Read only when `data` is a map and the schema
  is a non-empty list. A boolean `ecommerce` never reaches the category write.
- **Amount reader.** Reprice uses `CatalogueView.to_decimal/1`, the storefront
  reader, including its acceptance of a trailing suffix. See the #122 review
  for why that stays.

## Verification

No code change in the catalogue leg in this pass. `mix precommit` passed on
the tree that includes the cart-move ceiling fix. The full suite's two
failures are the pre-existing image-downloader log assertions described in
the #122 review; nothing in the reprice tests failed.
