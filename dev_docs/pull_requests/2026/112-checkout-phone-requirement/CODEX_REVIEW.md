# PR #112 — checkout phone requirement

Reviewed 2026-10-29, merged commit `bcd67c4`, rechecked on `851f31a`.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/112

## BUG - MEDIUM — non-text values satisfy the required phone check

The context's completeness check considered every non-string, non-nil value
present. With the phone setting enabled, otherwise valid billing data carrying
`"phone" => false` created an order whose billing snapshot contained that
boolean. Form validation alone cannot protect the public conversion function
or a crafted checkout event sequence.

Fixed the supplied-billing-data completeness check to accept only nonblank
text. This also prevents malformed required name and address values from
satisfying completeness. Presence remains a separate question: malformed
names still count as submitted billing details, so they cannot be mistaken
for an untouched form and skip the phone requirement. Regressions check
booleans, a number, a list, and a map, and confirm each refusal leaves the
cart active.

## BUG - MEDIUM — a new requirement returns a stale billing form

If an administrator enabled the phone requirement after a shopper reached
review, conversion correctly refused a blank phone. For newly entered details,
the error handler then returned the old changeset: the phone had no field
error and its required attribute was stale on billing versions that support it.

Fixed the incomplete-billing handler to rebuild and validate the form after
restoring any saved-profile data. Saved-profile recovery uses that same single
rebuild. A LiveView regression enables the setting during review and asserts
the returned form highlights the phone, including its required attribute when
the installed billing supports it.

Both regressions failed against the merged implementation before the fixes.
See [FOLLOW_UP.md](FOLLOW_UP.md) for validation.
