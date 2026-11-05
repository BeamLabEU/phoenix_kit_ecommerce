# PR #114 — Start the online payment at checkout and wait for it on the order page

- **Author:** Tymofii Shapovalov (timujinne)
- **Merged:** 2026-10-29, `45fac9d`
- **Reviewer:** Claude, 2026-11-05, against `main` at `0337d18`, after Codex's four
  fixes

## What was checked

- **The billing contract, on billing's `main`.** `OnlinePayment.start/3` handles
  every documented answer of `start_order_payment/2`. Billing refuses a call made
  inside a transaction, and `handle_order_result/2` runs after the conversion
  committed. The function is not on Hex yet (0.24.0 lacks it), so the feature stays
  dormant behind `supported?/0` until billing's next release.
- **The webhook path.** `billing_invoice_event_handlers/0` is found through
  `ModuleRegistry`. The handler covers all six order statuses. An invoice that lands
  before the order moves gets `{:error, :order_not_paid_yet}`, which the worker
  retries up to 20 times, and a terminal status ends the job.
- **Idempotency.** The marker is written under `FOR UPDATE` in the notification's
  transaction, from the metadata read under that lock. Core's
  `Notifications.create/1` rescues into `{:ok, :skipped}`, but a database failure
  there aborts the transaction, so the marker write raises and the job retries
  rather than recording a message that was never stored.
- **Return URLs.** `origin/1` only picks among origins the site itself serves and
  returns the site's spelling. A forged host falls back to `Routes.base_url/0`.
- **Core floor.** `Routes.canonical_host/1` first shipped in core 2.64.0, below the
  2.65.0 floor.

## Findings

### IMPROVEMENT - MEDIUM — a public page subscribed to every order in the shop (fixed)

`CheckoutComplete.mount/3` called `Billing.Events.subscribe_orders()`, the shop-wide
topic billing's admin pages use, before the access check. Every open confirmation
page, including a guest's, then received every order struct in the shop (with its
billing snapshot) and woke up for each one. None of it reached a browser:
`handle_info/2` drops other orders and logs only the message's shape. It was still
a fan-out that grows with open pages times orders, on a page anyone can hold open,
and order data did not belong in those processes.

Now the page subscribes to the buyer's own topic (`subscribe_user_orders/1`), and
only after the access check. That topic is only known once the order is, so a
connected mount reads the order again after subscribing, which keeps the guarantee
the old ordering gave. Cost: one more read on connected mounts.

The subscription test failed before the fix with
`right: ["phoenix_kit:billing:orders"]`. A second test covers a guest's page updating
through the new topic. The re-read itself has no test: the window it closes cannot
be hit from a LiveView test without a hook in production code.

### IMPROVEMENT - MEDIUM — online payment starts on orders with price-on-request lines (open: needs a decision)

`OnlinePayment.required?/1` looks only at the total, and nothing in the conversion
or the checkout looks at on-request lines (`any_line_on_request?/1` is display only).
An on-request line contributes 0, so a mixed cart sends the buyer to the provider
for the priced lines alone. Once that invoice is paid the order is `paid`, and
billing's `Order.editable?/1` only allows `draft` and `pending`, so the merchant can
no longer add the quoted amount to it. Before this PR that order stayed `pending`
until someone dealt with it. An on-request-only order totals 0 and is unaffected.

The buyer does see "Items priced on request are not included in this total", so
this is not a silent overcharge. Not changed here, because either answer changes
what a buyer is asked to pay:

- **Recommended:** make `required?/1` false for an order with an on-request line. No
  redirect and an immediate confirmation, and the merchant quotes, then invoices.
- Keep the current behaviour and bill the quoted line separately.

### IMPROVEMENT - MEDIUM — the order-page tests would break on billing's next release (fixed)

Eight tests set an order's status with `Billing.update_order/2`, which billing's
`main` refuses ("an order is moved to paid by its own action"). They pass on Hex
0.24.0 only because that check is not released yet. Production code does not depend
on it: no call in `lib/` passes a status. A new `put_status!/2` writes the row
directly, the way the refund test here already did, so they pass on both billings.
Found by running these tests against billing `main` to exercise the real chain,
which is excluded on Hex.

### NITPICK — a failed start loses its reason on the first page (left open)

`pay_online/2` drops the reason, so a shop with no configured provider shows "We
could not start the payment. Please try again." instead of the `:payment_unavailable`
text. "Pay now" then shows the right one. Carrying it needs a second URL hint for
one sentence.

### NITPICK — one possible duplicate confirmation across a billing upgrade (left open)

An online order placed while billing lacked `start_order_payment/2` got its
confirmation at once. If its invoice is paid after the upgrade, `required?/1` is true
and no marker exists, so the buyer gets a second inbox message. It can only affect
orders open at that one upgrade, and it is one message.

Validation is in [FOLLOW_UP.md](FOLLOW_UP.md).
