# 0.12.0 release: follow-up

How each finding in `GROK_REVIEW.md` was resolved.

## BUG - MEDIUM: a stale `:paid` can write off after a concurrent refund

**Fixed.** Confirmed: billing's `OrderEventWorker` delivers `:paid` and
`:refunded` as separate jobs on the `billing` queue (`oban_queues/0` is
`[billing: 10]`), so they can overlap. A `:refunded` that ran before the sale
was posted found neither the sale nor the short mark and ended, and nobody was
told.

The suggested fix (lock the order `FOR UPDATE` around the write-off) was not
taken. `GoodsIssues.create_and_post/2` runs its own transaction, and a refused
posting (`{:insufficient_stock, _}`) would roll back the enclosing one, taking
the short-stock notification and its mark with it (the "rollback poisons the
surrounding transaction" landmine in AGENTS.md).

Instead, `OrderStockHandler.write_off/3` re-reads the order once the write-off
is settled (posted, already posted or flagged short). If it is `refunded` by
then, the refund step runs from there (`settle_refund/1`). Every interleaving
is covered: a refund committed before the re-read is handled by the write-off,
and one committed after it enqueues a `:refunded` that sees the sale. Both
paths are idempotent: the told mark for "notify", `external_ref` for "receipt".
A return that two deliveries post at the same moment loses to the unique
`external_ref` and counts as done (`posted_twice?/1`), not as a refusal that
would notify.

Tests: "a refund that lands while the sale is being written off" in
`order_stock_handler_test.exs` (4 tests). A stand-in `GoodsIssues` refunds the
order inside the posting call. 3 of them fail with `settle_refund/1` disabled.
The fourth checks that a second delivery does not post the receipt twice,
which holds either way.

## IMPROVEMENT - MEDIUM: low-stock cap duplicated in three places

**Fixed.** `StockTracking.max_low_stock_threshold/0` is the single source. The
settings input's `max` and `Errors.message(:invalid_low_stock_threshold)`
(`"Enter a whole number from 0 to %{max}."`, re-translated in et/ru/uk/de/fr)
read it. The pinned English text in `errors_test.exs` is unchanged.

## NITPICK: product-page comment restates the `:if`

**Left.** It names where the value comes from and which setting drives it,
which the `:if` alone does not.

## NITPICK: leftover core/billing feature detection

**Left for a later cleanup.** `API.CartTools.gate_available?/0` and
`replay_available?/0` are dead branches under core 3.5, but not wrong. The
billing probes in `test_helper.exs` guard against billing's floor (`~> 0.25`),
not core's, so they need checking against billing 0.25.0 before removal.

## NITPICK: `phx-change` on an already-selected refund action

**No change needed.** A `<select>` fires `change` only when the value changes,
so choosing the option already selected sends no event and logs nothing.
