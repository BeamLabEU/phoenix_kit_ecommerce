# PR #114 — online payment at checkout

Reviewed 2026-10-29 against merged commit `45fac9d`, on `54ab1df`.
Author: Tymofii Shapovalov (`timujinne`).
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/114

Compared the recent merges with the existing Codex reviews. PRs #109–113
already have reviews; #114 is the newly merged, unreviewed change. Checked
the billing handoff and its installed/local implementations, trusted return
origins, free and closed orders, customer access, PubSub updates, and durable
invoice-event delivery. Applied the Phoenix and Ecto thinking skills.

## BUG - HIGH: redelivery sends duplicate customer confirmations

Billing explicitly delivers invoice events at least once. The handler sent
the customer notification on every `:paid` delivery, so a worker retried after
the first successful send created another inbox entry and another opportunity
for external delivery. The PR describes this as a known limitation.

Fixed by locking the order and recording `_shop_payment_notified` in its
metadata in the same transaction as the notification insertion. A repeat
delivery becomes a no-op. The internal delivery marker preserves other
metadata, the business revision and `updated_at`. Notification insertion
errors now reach the durable worker instead of being swallowed by the
checkout's best-effort wrapper; rollback removes both notification and marker.
Disabled or preference-filtered notifications remain intentional skips.

Regression tests cover repeated delivery, metadata/revision preservation and
rollback followed by successful redelivery. The duplicate-delivery test failed
against the merged implementation with two identical notifications.

## BUG - MEDIUM: delayed confirmation loses the buyer's language

Checkout previously passed its page language directly to the notification.
The new worker called `order_paid/1` without that language, so a German
checkout produced an English-language order link on an English-primary site.

Fixed by recording `checkout_language` when converting the cart and passing
it from the stored order to the delayed notification. The existing language
validation/fallback still handles unavailable languages and older orders.
Tests cover a localized LiveView checkout and the eventual notification URL;
the URL test reproduced `/en/dashboard/orders/...` instead of `/de/...` before
the fix.

## BUG - MEDIUM: mutable payment options change an order's payment state

`OnlinePayment.online?/1` read the payment option live. Editing an online
option to offline made an unpaid order render the success header and removed
Pay now; the invoice handler also stopped recognizing its eventual payment.
Changing an offline option to online caused the inverse misclassification.

Fixed by snapshotting `payment_option_type` alongside the existing payment
code at checkout and preferring that snapshot. Older orders keep the live
lookup fallback. Tests cover both edit directions and the persisted checkout
snapshot; the online-to-offline regression failed before the fix.

The snapshot preserves the order's payment classification; billing still
decides whether its current provider configuration can start a payment. It
does not resurrect a deleted payment option or override billing's rules.

## BUG - MEDIUM: immediate confirmations are sent again on invoice payment

On older billing, and for a zero-total order, checkout sends the customer
confirmation immediately. The invoice handler checked only the option's
online type, so a later paid-invoice event sent a second confirmation even
on its first delivery. Both paths reproduced duplicate notifications.

Extracted `OnlinePayment.required?/1` as the shared, status-independent rule
for a supported online payment with a positive total. The waiting page and
the invoice handler now apply the same rule. These immediate-confirmation
paths neither send another message nor keep retrying an unpaid invoice
event. Regression tests cover older billing and a free order.

## Validation and remaining scope

See [FOLLOW_UP.md](FOLLOW_UP.md) for final suite and gate results.

The default existing test database is below core 3.0's migration floor, so
integration validation uses isolated disposable databases. The existing
database is preserved.

No additional finding in return-origin validation or the rule that a provider
return URL cannot mark an order paid. Untrusted host aliases still fall back
to the configured site origin, and a guest cookie on another alias may not
authorize the returned page. Live provider behavior, including 3-D Secure,
requires provider testing; request stubs exercise the billing integration.
Abandoned orders and direct manual order payment without an invoice retain
the PR's documented behavior. No release or dependency-floor change.
