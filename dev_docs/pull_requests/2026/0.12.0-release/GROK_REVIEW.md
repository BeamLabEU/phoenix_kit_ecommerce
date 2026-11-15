# 0.12.0 release recheck (Hex 0.11.0 → local main)

- **Author:** Dmitri Don (fotkin)
- **Reviewer:** Grok
- **Scope:** `0.11.0` (Hex 2026-11-11) .. `ca27e51` (local main, unpushed)
- **Verdict:** ready to publish. No ship-blockers.

Local main is three commits ahead of `origin/main`:

| SHA | Subject |
|---|---|
| `3467a07` | Update the core floor to 3.5.0 and remove the old-core shims |
| `c29f56d` | Add the refund, low-stock and "N left" parts of stock tracking (#82) |
| `ca27e51` | Bump version to 0.12.0 |

`origin/main` already has `1369230` (mix.lock, phoenix_kit 3.5.0 and transitives). Hex latest is **0.11.0**.

## Summary

0.12.0 finishes stock tracking (#82) and raises the PhoenixKit core floor from `>= 2.65.0 and < 4.0.0` to `>= 3.5.0 and < 4.0.0`. Refunds either notify (default) or post a goods receipt; a write-off that crosses a Warehouse minimum sends `shop.stock_low` once; the product page disables Add to Cart when sold out and can show "Only N left". Settings fail closed, Authz gates the new events, `once/3` holds refund/short notifies to one, Warehouse `external_ref` makes postings idempotent, gettext covers all six catalogues, and the CHANGELOG upgrading note is honest.

An independent reviewer of the same diff found no correctness bugs (two maintenance suggestions, recorded below).

## Checked, correct

- **Core pin.** `mix.exs` is `>= 3.5.0 and < 4.0.0`; `core_pin_conformance_test.exs` admits 3.5.x/3.6.0/3.9.9 and rejects 2.65.0/3.4.x/4.0.0. `version/0` is `Mix.Project.config()[:version]` (`0.12.0`). Lock was already 3.5.0 on origin; the unpushed work only raises the mix.exs floor.
- **Shim removal.** Admin tools, `FlowConfig.confirm_batch_over/0`, `RateLimit.check_new_rows/1`, and `Routes.canonical_absolute_or_nil/2` call core 3.5 directly. `confirm_batch_over/0` is `pos_integer()` (default 50); `length(rows) > batch_over` is safe. Cart tools still feature-detect `Keys.active?/1` / `ControlFields.replay_tool?/1`; under 3.5 both exist.
- **Paid write-off.** Shop-checkout orders still `paid` on the payload post one sale (`reason: "sale"`, `external_ref: order_number`). Billing's `OrderEventWorker` re-fetches the order before delivery, so a `:paid` job that runs after a refund sees `status: "refunded"` and no-ops (tested). Short stock flags `_shop_stock_short` with the notification.
- **Refund.** `"notify"` (default, fail-closed) tells keepers once via `_shop_refund_stock_told`. `"receipt"` posts `"<order_number>/return"`; Warehouse `already_posted` makes a retry a no-op. A refused receipt logs and notifies instead of retrying. Short-when-paid always notifies. `:cancelled` is ignored.
- **Low stock.** `crossed_minimum/1` compares all-warehouse stock to `MinStockSettings`, names an item only when the issue crossed the line. `item_lines/1` sums duplicate SKUs so a multi-line order of one item cannot miss. Best-effort; a redelivery of an already-posted sale sends none.
- **Product page.** `Availability.offer/1` is `:available | {:few_left, pos_integer()} | :sold_out`. Threshold `0` never shows "Only N left". Sold-out disables the button. `handle_info({:inventory_updated, uuid, _})` compares the catalogue item uuid (same as `StockTracking.item_uuid/1`) and refreshes `offer`. `put_content_locale/1` and `ignore_event/2` are in place. ngettext `"Only %{count} left"` has ru/uk `msgstr[2]`.
- **Settings.** New events go through `Authz.authorize(socket, :manage_settings, ...)` into `gated_event/3`; Activity logs on `{:ok, _}`. `manage_catalog` cannot save them (`authz_test.exs`). Wrappers fail closed. Threshold 0..1000; refund action `"notify" | "receipt"`.
- **Notifications.** `shop.order_refunded_stock` and `shop.stock_low` join the stock type. Links are `Routes.path("/admin/warehouse/goods-issues")` and `.../goods-receipts`, matching Warehouse's admin paths.
- **Errors.** `:invalid_low_stock_threshold`, `:invalid_refund_action`, `:stock_setting_update_failed` have `Errors.message/1` clauses and tests.
- **Gettext.** New strings extracted; et/ru/de/fr/uk translated; no fuzzy entries.
- **CHANGELOG.** Dated 2026-11-15; breaking core floor and safe defaults (refund notify, threshold 0) are called out. No migration.

## Findings

### BUG - MEDIUM — a stale `:paid` payload can still write off after a concurrent refund

- **File:** `lib/phoenix_kit_ecommerce/order_stock_handler.ex` (`write_off/3`, `handle_order_event(:paid, ...)`)
- **What.** The `:paid` clause matches the **in-memory** order. Billing re-fetches at job start (`OrderEventWorker.perform` → `get_order/1`), which closes the usual "refunded before the job ran" case. The remaining window is: `:paid` has already fetched `status: "paid"`, a refund commits, `:refunded` finds no `sale_issue` and no short flag and returns `:ok`, then `:paid` posts the sale. Billing's `:billing` queue runs at concurrency **10**, so the two jobs can overlap.
- **Why it is not a ship-blocker.** Typical refunds are minutes to hours later; by then the sale is posted and `:refunded` finds it. A `:paid` job that starts after the refund already no-ops (tested). 0.11.0 already wrote off regardless of a later refund. Outcome of the window: stock stays written off and nobody is told — the keeper would have to notice.
- **Fix, if taken later.** Lock the order in `write_off/3` (`FOR UPDATE`), re-read `status`, and skip unless it is still `"paid"`. Add a test that calls `:paid` with a paid-shaped struct whose row is already `refunded`. Not applied here: it is a narrow TOCTOU, not the path the feature is for.

### IMPROVEMENT - MEDIUM — low-stock cap duplicated in three places

Independent reviewer. `StockTracking.@max_low_threshold` (1000), the settings input `max="1000"`, and the gettext `"Enter a whole number from 0 to 1000."` must stay in sync. Drive the input max from the module attribute and interpolate it in the error string. Left as-is for this release; the cap is not changing.

### NITPICK — product-page comment restates the `:if`

Independent reviewer. The HEEx comment above `#product-stock-left` repeats `Availability.offer/1` / the threshold. Harmless.

### NITPICK — leftover core/billing feature detection

`API.CartTools.gate_available?/0` and `replay_available?/0`, and `test_helper.exs` billing excludes (`user_menu_with_shop?/1`, `put_order_sync/2`, `start_order_payment/2`), still `function_exported?/3` against APIs that 3.5 / billing 0.27 always have. Dead branches, not wrong.

### NITPICK — `phx-change` on an already-selected refund action

Re-selecting `"notify"` can write the same setting and log `shop.stock_refund_action_changed` again. No functional harm.

## Not bugs (documented or pre-existing)

- Low-stock notify is best-effort: a crash after `post_sale` and before `stock_low/1` is not retried (`already_posted` skips it). Two concurrent write-offs can both see a crossing.
- Catalog cards do not show stock; Legacy products are never limited; nothing is reserved. Spec #82 "not there yet".
- Admin products list reloads on any `inventory_updated` (pre-existing; refunds now also broadcast).
- Quantity selector is not capped by on-hand (pre-existing; `add_to_cart` still refuses).
- Product page still loads data in `mount/3` (pre-existing for this LiveView; `offer/1` is one more read on that path).
- English `.po` empty `msgstr` is Gettext 1.0 (msgid is the English).

## Tests and gate

- Focused stock / core-pin / authz / errors / settings / product-page suite: **205 tests, 0 failures**.
- Full `mix test`: **5201 tests, 0 failures** of this release. Two `ImageDownloaderTest` failures appeared only under `unbuffer` (Logger ANSI in `CaptureLog`); the same file is **22 tests, 0 failures** without a TTY. Those tests are not in `0.11.0..HEAD`.
- Excluded: `:old_catalogue`, `:no_catalogue`, `:analytics` (4). Catalogue and warehouse families ran.
- `mix precommit`: compile `--warnings-as-errors`, `deps.unlock --check-unused`, `hex.audit`, `format --check-formatted`, `credo --strict`, dialyzer (8 skipped, 0 new). Clean.

Storefront UI was checked through `stock_limits_pages_test.exs` (sold out, "Only 2 left", live `inventory_updated`). No host app was running, so there was no browser pass.

## Publish notes (when asked)

- Tag form of the newest tag is `0.11.0` (no `v` prefix).
- Do not tag before push + `mix hex.publish --yes`.
- Hosts on core `< 3.5.0` must update core first. No shop migration.
- New settings start at notify / threshold 0.
