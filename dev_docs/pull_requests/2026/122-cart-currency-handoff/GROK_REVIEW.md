# PR #122 — Cart currency, line moves, and the shop half of cross-domain handoff

**Reviewed:** 2026-11-23
**Reviewer:** Grok
**Range:** Hex `0.12.0` (`8309cb3`) through `2463131`, including the merge of
[#122](https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/122) (`2ba1e76`)
and the follow-ups already on main
**Head at review:** `2463131`

## Summary

Since 0.12.0 the shop learned three things: an active cart follows the request
currency (`redenominate_cart/2`, mount only), `move_cart_lines/3` is the shared
mover for the claim's "add" merge and the handoff, and `handoff_snapshot/1` /
`handoff_apply/2` carry a guest cart across domains. The earlier findings on
this range (double conversion on a stale rebase, a stored label read as another
variant's key, a first-visit cookie forced `secure: true`, `@impl` against a
core that does not list the callbacks yet, the fabricated `%Plug.Conn{}`) are
already fixed on main. See `CODEX_REVIEW.md` and `VIBE_REVIEW.md`.

One defect was still open. A storefront handoff capped every line at the cart
API's quantity (99). The storefront itself allows 9,999. With `keep_skipped:
true` the leftover stayed in the source, and the next handoff found the target
already at 99 and moved nothing.

## Findings

### 1. [BUG - MEDIUM] Every move used the cart API quantity cap — FIXED

**File:** `lib/phoenix_kit_ecommerce/cart_move.ex` (`room_for/4`)
**Confidence:** 95/100

`room_for` subtracted from `CartWriter.max_quantity()` (99) for every caller.
`add_to_cart/4`, the cart page and the product page cap at
`CartItem.max_quantity()` (9,999). A guest cart with a line above 99, or a
target line whose sum would pass 99 and not 9,999, was reported
`:quantity_cap`. The handoff keeps what it cannot move, so the remainder sat
in the source cart. The next handoff saw the target already at 99, `room_for`
returned 0, and those units never arrived.

The claim merge must keep the API cap: the public cart API refuses a quantity
above 99, and `claims_test.exs` pins that a browser cart already at that cap
skips the API line.

**Fix:** the ceiling defaults to `CartItem.max_quantity/0`. `Claims.merge!/3`
passes `max_quantity: CartWriter.max_quantity()`. A value above the cart
ceiling, or one that is not a positive integer, is the cart ceiling, which is
also what `add_to_cart/4` will accept. The handoff passes no cap. Regression
coverage: a quantity above 99 moves in full on `move_cart_lines/3` and on
`handoff_apply/2`; the API-cap cases pass the option; the claim test is
unchanged and still passes.

## Checked, left as they are

- **Handoff task deadline.** Core runs the apply hook in a task with a 5 second
  deadline and no process dictionary. A kill after `move_cart_lines/3` commits
  and before the cookie is collected can leave a minted cart the browser never
  hears about. That window belongs to core's deadline. A shop cart large
  enough to exceed it is outside what this change should paper over.
- **Currency change before a failed move.** When a caller passes `:currency`,
  `handoff_apply/2` re-denominates the target and then moves. A later
  `{:error, :busy}` leaves the target in the new currency and the source
  intact. Core's context names no currency, so that path is a no-op and the
  cart page re-denominates on mount. A caller that does pass `:currency` sees
  a currency change without a line move. Acceptable: the page would have moved
  the currency anyway, and the lines are not lost.
- **Tax is still rounded to 2 decimal places** inside `recalculate_cart_totals!/1`.
  That predates this range. Re-denominating into a 0-decimal currency makes it
  visible once tax is non-zero. Changing it would retouch every cart
  recalculation, not only a handoff. Left for a change that owns tax.
- **`compare_at_price` on a rebase** is kept even when rounding leaves it no
  longer above the unit price. Re-denomination drops it, and that path is
  tested. The two operations are documented that way.
- **`CatalogueView.to_decimal/1`** keeps a leading number and ignores the rest
  (`"10.00 USD"` parses as 10). The catalogue reprice reads amounts through
  that function on purpose, the same reader the storefront uses. `API.Money`
  is stricter and is not this path.
- **Core pin.** `handoff_snapshot/1` and `handoff_apply/2` are optional and
  annotated only when the installed core lists them. The floor stays
  `>= 3.5.0 and < 4.0.0`. Raise it when the handoff-capable core is the
  published floor, in `mix.exs` and `core_pin_conformance_test.exs` together.
- **Unpublished 0.13.0 changelog.** `CHANGELOG.md` describes only the catalogue
  reprice (#120). Cart currency, the handoff, and this cap fix are on the same
  unpublished version. Fold them into the 0.13.0 notes at publish time. This
  pass does not edit the changelog or the version.

## Verification

- `mix precommit` passed (compile `--warnings-as-errors`, unused-lock check,
  `hex.audit`, Credo strict, Dialyzer).
- Focused run: `cart_move_lines_test.exs`, `cart_handoff_test.exs`,
  `api/claims_test.exs` — 181 tests, 0 failures.
- Full `mix test`: 5453 tests, 2 failures, 4 excluded. Both failures are
  `ImageDownloaderTest` "a content type the server made up" and are not in
  this range (the downloader did not change since 0.12.0). They fail only
  when Logger colors are on: `capture_log` then contains the formatter's
  `\e[33m` / `\e[0m`, which the assertions treat as part of the content type.
  Left as they are.
