# PR #111 — newest products first with hidden categories excluded

Reviewed 2026-10-29, merged commit `a76ae6d`, rechecked on `851f31a`.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/111

No new functional finding. The hidden-category subquery removes the
DISTINCT ON ordering override without duplicating products. Its UUID primary
key cannot contribute NULL to NOT IN, and the explicit NULL category branch
retains uncategorized products. Active and unlisted categories remain visible.
Both list paths order by insertion time and UUID descending, including ties
and pagination. Checked the remaining query filters for multiplicative joins.

The product context and permission tests passed together: 82 tests, zero
failures. Final validation is in the
[PR #112 follow-up](../112-checkout-phone-requirement/FOLLOW_UP.md).
