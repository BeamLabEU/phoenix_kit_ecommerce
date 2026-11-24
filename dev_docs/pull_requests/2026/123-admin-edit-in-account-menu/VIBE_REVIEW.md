# PR #123 — Hand the admin Edit target to the host layout; in-page button behind a setting

**Author:** timujinne · **State:** merged 2026-11-24 (`bb979fe`) · **Reviewed:** 2026-11-24

Storefront pages already computed a permission-gated admin Edit target
(`Web.Helpers.maybe_assign_admin_edit/4`) but showed it only as an in-page button in the
storefront bar. The PR hands the target to the host layout through
`ShopLayouts.shop_layout/1` → `LayoutWrapper.app_layout`'s `admin_edit_url`/`admin_edit_label`
attrs (core ≥ 2.22.2, published), and moves the in-page button behind a new setting
`shop_show_admin_edit_button`, default off.

**Verdict:** merged. No code findings; one behavior change called out below, deliberately.

## Checked, fine

- **The hand-off uses the attrs, not `module_assigns`.** Core's `app_layout` doc is explicit
  that a `module_assigns` value skips the permission gate — the PR passes the attrs and lets
  core re-run nothing (the gate already ran in `maybe_assign_admin_edit/4` on the socket).
  The test layout (`Test.Layouts.host/1`) reads exactly what a host layout would see.
- **The permission gate is unchanged and pinned from three angles:** admin with the shop
  permission gets the target in the host layout (`#host-admin-edit`), a guest and an admin
  with `permissions: []` / `["shop"]` get nothing, on the shop index, category and product
  pages (`storefront_admin_edit_menu_test.exs`).
- **The in-page button switch.** `storefront_bar/1` renders the Edit link only when
  `admin_edit_url` is set AND `shop_show_admin_edit_button` is on; the bar wrapper renders
  when the cart bar or the button shows, so no empty row. `data-storefront-bar` is an inert
  test hook, documented as such in a comment. The settings toggle reuses the existing
  `<.setting_toggle>` component and the same `Authz.authorize(socket, :manage_settings, …)`
  gate as `toggle_cart_bar`; the permission-refusal path is tested
  (`settings_admin_edit_button_test.exs`). The rescue-fail-closed pattern in
  `show_admin_edit_button?/0` matches `show_cart_bar?/0` beside it.
- **Existing button tests were updated, not deleted:** `storefront_admin_edit_test.exs` and
  the `:catalogue` describes in `admin_edit_origin_test.exs` now set the setting on in setup,
  with a comment saying why (they assert the in-page button; the menu path has its own test).
- **gettext:** the four new msgids are in `default.pot` and all six locales (de, en, et, fr,
  ru, uk), with reference comments pointing at the new lines.

## Behavior change (deliberate, documented in the PR body and AGENTS.md)

Default off means a host whose header does not render `admin_edit_url` loses the in-page
Edit link on upgrade until it switches `shop_show_admin_edit_button` on. That is the intended
trade (the target now belongs in the host's account menu), and it is written down in the
module's AGENTS.md and the engineering reference.

## Validation

- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`,
  dialyzer via `mix precommit` — clean (run against the post-sweep core release).
- `mix test` — full suite passes, including the new `storefront_admin_edit_menu_test.exs` and
  `settings_admin_edit_button_test.exs`.
