# Follow-up: PRs #84–#88 review (2026-10-13)

Resolutions for `CLAUDE_REVIEW.md`. Numbers are the review's.

| # | Finding | Resolution |
|---|---------|------------|
| 1 | Storefront fallback reflects a redirect target's body | Fixed: 3-redirect cap, body reported by shape. Private-host restriction left open (needs the image importer's guard shared) |
| 2 | Bulk uuids not cast on products/categories | Fixed: `Helpers.cast_uuids/1`, `cast_optional_uuid/1`; `bulk_payload_hardening_test.exs` |
| 3 | Reprice from an unlocked read | Fixed: `Options.transform_global_options/1`; `transform_global_options_test.exs` |
| 4 | Editing an option renames it | Fixed: `keep_editing_key/2`; test submits no key |
| 5 | Picked image lost on broadcast | Fixed: `selectable_image_urls/1`; test fails without the fix |
| 6 | Concurrent double confirm | Fixed (no test: race not reproducible in a LiveView test) |
| 7 | Migration stats query volume | Fixed: 1 s debounce; test added |
| 8 | Failed product-source read retried | Fixed; no test (shared sandbox cannot make the read fail) |
| 9 | Pre-#84 guest accounts locked out | Open: V4 backfill vs release note — owner decision |
| 10 | Media-sync "interrupted" re-check unreachable | Open |
| 11 | `deduplicate_products` prefix-unaware, bogus order_items table | Open (pre-existing) |
| 12 | Category option edits whole-list | Open |
| 13 | Catalogue counts include soft-deleted | Open — decision on dashboard semantics |

## Gate

`mix precommit` clean (format, `compile --warnings-as-errors`, credo
--strict, dialyzer). The `:catalogue`-tagged suite was not run.

## Full suite: 20 failures that are not from these changes

`mix test` gives 2965 tests, 20 failures — the same 20 on a clean checkout of
`main` (verified with the changes stashed): `LegacyFormsReturnToTest`,
`AdminEditOriginTest`, `StorefrontAdminEditTest`, one `ShopifySyncTest`, one
`ShopifySyncMediaPanelTest`, one `TranslationsTest`.

Cause, for the ones checked: the `libs` bump moved core to 2.62.x, where a
single-language site emits no locale segment (core 2.62.0 changelog), and the
test site is single-language. Tests that assert `/en/admin/...` get
`/admin/...`. `ShopifySyncMediaPanelTest` fails on a `push_patch` to a path the
test router does not define, and `TranslationsTest` on a "Sweep ran" flash
that now reads "Sweep did not run — AI translation isn't available" (the
installed `phoenix_kit_ai`). The fix belongs in `test/test_helper.exs`
(enable a second language, or assert the clean paths); not done here because
it touches every path assertion and the other agent is still working in this
tree.
