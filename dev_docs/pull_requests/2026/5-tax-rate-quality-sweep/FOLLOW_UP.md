# PR #5 follow-up — Fix order tax_rate bug + quality sweep

Triaged 2026-08-04 during the ecommerce quality sweep. All six findings in
`CLAUDE_REVIEW.md` were re-verified against current code.

## Fixed (pre-existing)

- ~~**#2 Tax fallback ignored `billing_tax_enabled?`**~~ — fixed in the PR itself.
- ~~**#3 `--warnings-as-errors` broken on `main` by a later lib upgrade**~~ — fixed in the PR itself.
- ~~**#1 `PhoenixKitEcommerce.Errors` shipped with zero call sites**~~ — partially resolved in the PR; still 2 call sites in `lib/` (`web/checkout_page.ex:487`, `web/imports.ex:323`). This was explicitly designed to be incremental — the remaining sites return `%Ecto.Changeset{}` rather than atoms, and routing those through `Errors.message/1` would surface `"Unexpected error: #Ecto.Changeset<...>"`, which is worse than the current generic string. Adoption tracks new atom contracts as they appear; not a debt item.

## Fixed (Batch 1 — 2026-08-04)

- ~~**#4 Order tax basis can diverge from the persisted order country**~~ — **now fixed.** The review deferred this because "a correct fix means recomputing `tax_amount` (not just the rate) from the *resolved* country at conversion time — otherwise the rate and the amount would be inconsistent". That is exactly what `apply_checkout_shipping_country/2` now does: it resolves the country through the same `get_shipping_country/3` the order attrs use, writes it onto the cart, and recalculates totals **before** the order copies them. The order's country, `tax_rate` and `tax_amount` are now all derived from one resolved value.

  It also turned out the deferral was hiding a bigger bug: `get_tax_rate/1` returns 0 for a nil-country cart, the cart page deliberately nils the country, and nothing ever set it — so *every* order was tax-free. See `lib/phoenix_kit_ecommerce.ex` (`apply_checkout_shipping_country/2`) and `test/phoenix_kit_ecommerce/regression/tax_rate_test.exs`.

- ~~**#5 DB writes in `mount/3`**~~ — the write half is fixed. `web/import_configs.ex:17` seeded via `ensure_default_import_config/0` + `ensure_prom_ua_import_config/0` on every mount, and `mount/3` runs twice per page load (HTTP render + WS connect), so every visit attempted the same two writes twice. Now gated on `connected?/1`.

  The read half — unconditional queries in `carts.ex`, `shipping_methods.ex`, `dashboard.ex`, `imports.ex` mounts — is **not** changed here; see Open.

## Skipped (with rationale)

- **#6 The no-billing fallback branch is untested.** `PhoenixKitBilling` is always loaded in the test env, so `Code.ensure_loaded?(PhoenixKitBilling)` is always true and the `else` branches of `billing_tax_rate/0`, `billing_tax_rate_percent/0` and `billing_tax_enabled?/0` are unreachable from tests. Exercising them means unloading a compiled dependency mid-suite. Left as a known coverage gap, consistent with the playbook's guidance that the residual coverage budget goes to defensive fallbacks the runtime swallows before reaching.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce.ex` | `apply_checkout_shipping_country/2` resolves + persists the checkout country and recalculates totals before order build (closes #4) |
| `lib/phoenix_kit_ecommerce/web/import_configs.ex` | seed writes gated on `connected?/1` (closes the write half of #5) |

## Verification

`mix precommit` exit 0 (format, compile --warnings-as-errors, credo --strict, dialyzer, deps.unlock --check-unused). Suite: 245 tests, 0 failures via `PHOENIX_KIT_PATH=../phoenix_kit mix test`.

No pre-existing failures in this module. (Core has one seed-dependent flaky test in `PermissionsTest`, unrelated to this module and confirmed to reproduce at its own base commit.)

## Open

- **#5, read half** — unconditional queries in the `mount/3` of `carts.ex`, `shipping_methods.ex`, `dashboard.ex` and `imports.ex`. Moving these to `handle_params/3` is a cross-cutting change across four LiveViews with no test coverage of the difference, and it is a performance concern rather than a correctness one (the queries are idempotent). **Surfaced for a decision rather than deferred unilaterally:** fix now, or give it its own PR with the DB suite green?
