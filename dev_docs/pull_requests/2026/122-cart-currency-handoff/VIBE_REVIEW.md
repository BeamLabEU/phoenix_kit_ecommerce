# PR #122 — Cart follows the request currency; move_cart_lines/3; shop half of the cross-domain handoff

**Author:** timujinne · **State:** merged 2026-11-23 (`2ba1e76`) · **Reviewed:** 2026-11-23

Reviewed at the PR head plus a gate run against local core (which carries #1058's
`PhoenixKit.Module.handoff_snapshot/1` / `handoff_apply/2`).

**Verdict:** merged. One finding, fixed on main: the two handoff callbacks lacked
`@impl PhoenixKit.Module`, which fails `compile --warnings-as-errors` against a core
that declares the callbacks (the published Hex core does not have them yet, so the
author's gate was green). Fixed in the follow-up commit on main.

## Checked, fine

- `CartMove.move/3` (`cart_move.ex`): identity locks taken in one fixed order (user keys
  sorted, then session keys sorted), both cart rows locked `FOR UPDATE` in uuid order in
  one statement with lines preloaded after the lock; `:same_cart` refused; deadlocks
  mapped to `{:error, :busy}`; with its own transaction the per-line PubSub events are
  held back and one `cart_updated` per affected cart is sent after commit
  (`broadcast: false` on the per-line path). The claim merge path (`API.Claims.merge!/3`)
  is unchanged and reuses the same core.
- `move_cart_lines/3` with `guest_source: true` re-checks under the row lock that the
  source is a guest, non-API, non-empty cart; `keep_skipped: true` leaves unmoved lines
  (and the remainder of a capped line) in the source, which becomes `merged` only when
  nothing is left.
- `CartHandoff` (the module callbacks): the snapshot names only a signed-out visitor's
  non-empty ACTIVE cart by uuid; the apply side trusts the payload no further than
  `guest_source/1` plus the locked re-check in `move_cart_lines/3`, never raises on any
  input, mints a session id only for a guest's first arrival, and discards a minted cart
  that ended up empty (no orphan cart, no cookie set). Module cookies/notices come back
  through core's validated effects path.
- `redenominate_cart/2`: one transaction, rebase, currency + frozen rate, every line
  re-derived from `base_unit_price` as an add-to-cart at that rate would price it;
  `:currency_unavailable` / `:no_base_price` / `:cart_not_active` leave rows untouched;
  same currency is a no-op without a query. Cart and checkout mounts call it only when the
  cart's currency differs from the request's display currency; a currency that fell back
  to the base never triggers it; a stored carrier quote is dropped on change.
- Docs updated where behaviour changed (`create_cart`'s frozen-rate wording, the
  `add_to_cart` `:broadcast` option); migration-free (no schema change).

## Findings

1. **BUG - MEDIUM (compile) — missing `@impl` on the new callbacks.** Against a core that
   declares `handoff_snapshot/1` / `handoff_apply/2` (local main after #1058),
   `PhoenixKitEcommerce` defines both without `@impl PhoenixKit.Module`, so
   `mix compile --warnings-as-errors` fails:
   "module attribute @impl was not set for function handoff_snapshot/1 callback".
   Fixed on main by adding `@impl PhoenixKit.Module` to both, matching the module's
   existing annotation style (`before_user_delete/1` etc.). Note: against the currently
   published Hex core (callbacks absent) the annotation is the one that warns, so this
   module now expects the core release that carries #1058 — which the ecosystem release
   order (core first) provides; the module's `pk_dep(:phoenix_kit, ...)` floor should be
   raised to that version at release time.

## Verification

- Full `mix precommit` + `mix test` against local core (`PHOENIX_KIT_PATH=../phoenix_kit`)
  run on main after the fix — see the sweep report for the result.
- `mix.lock` refreshed (`mix deps.update --all`) so the module's locked transitive deps
  (phoenix_live_view 1.2.15, phoenix_kit_templates 0.2.5, fresco 0.17.0, tessera 0.3.12,
  etcher 0.29.1) satisfy local core's requirements; committed as "Update dependencies".
