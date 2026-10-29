# AGENTS.md

Guidance for AI agents working on `phoenix_kit_ecommerce`.
Keep this file **under 30,000 bytes**; put detailed reference material in
[the engineering guide](dev_docs/guides/engineering-reference.md).

## Overview

E-commerce library plugged into a host Phoenix app: multilingual products and
categories, guest/user carts, checkout, shipping, CSV and Shopify imports,
admin LiveViews and a public storefront. Module key `"shop"`, settings prefix
`shop_`. Registers through `use PhoenixKit.Module`; core discovers modules
from BEAM files and generates routes from tabs and `route_module/0`.

- Required PhoenixKit deps: core `>= 2.43.0 and < 3.0.0`, billing `~> 0.20`.
  Optional: AI `~> 0.24`, Warehouse `~> 0.5`, web analytics. Catalogue is
  duck-typed, with no declared dependency or version floor. Guard optional
  integrations so a host without them compiles and runs.
- Checkout hands orders, invoices, tax and payments to `PhoenixKitBilling`.
  The provider webhook confirms payment. Only supported positive-total online
  payments defer the buyer's confirmation; admins are notified immediately.
  `InvoicePaymentHandler` locks the order and commits the notification with
  its idempotency marker; failures roll both back. Snapshot checkout language
  and payment type. Read the payment contract in the guide before changing it.
- Public context APIs stay scope-less; bundled admin pages enforce permissions.
  Public cart tools fill a cart and hand off to checkout; they expose no order,
  address or payment mutation.
- The storefront uses the host's layout. No module JavaScript or hooks.
  Deprecated `compat/` delegates are for old hosts only; add no new delegates.
- Core owns the ten baseline shop tables; this chain adopts and evolves them,
  adding the search index (V4) and cart claims (V5).

## Read before changing a subsystem

The linked sections retain the detailed contracts and settings inventory.
Read the relevant section before editing that subsystem; update it when its
contract changes.

| Work area | Reference |
|---|---|
| Dependency capabilities, routes, claim-token logging, integration boundaries, online-payment notifications | [Overview and non-goals](dev_docs/guides/engineering-reference.md#overview) |
| Module/file map, schemas, options, imports, PubSub and web layer | [Architecture](dev_docs/guides/engineering-reference.md#architecture) |
| Admin API confirmation, lock ordering, owned paths, image download restrictions, order tools | [Admin API tools](dev_docs/guides/engineering-reference.md#admin-api-tools) |
| Sub-permissions, notification fan-out, audit action names | [Permissions](dev_docs/guides/engineering-reference.md#permissions), [Notifications](dev_docs/guides/engineering-reference.md#notifications-and-the-audit-trail) |
| Defaults and setting wrappers, shipping/service/destination semantics, Shopify, related products, stock and translations | [Settings keys](dev_docs/guides/engineering-reference.md#settings-keys) |
| Migration targets, shipped versions, prefix-specific object names | [Database and migrations](dev_docs/guides/engineering-reference.md#database--migrations) |
| Harness, support modules, environment and dependency-specific test tags | [Testing](dev_docs/guides/engineering-reference.md#testing) |
| Shipping quote snapshots, public API visibility, search indexing, cart claims and ACP decision | [Feature notes](dev_docs/guides/engineering-reference.md#feature-notes) |
| Storefront price display and i18n | [Storefront guide](dev_docs/guides/storefront.md) |

## Commands

```bash
mix deps.get
createdb phoenix_kit_ecommerce_test   # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
PHOENIX_KIT_BILLING_PATH=../phoenix_kit_billing mix test
PHOENIX_KIT_AI_PATH=../phoenix_kit_ai mix test
```

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.
- `mix test.reset` — drops the test database and recreates it.
- `mix test.setup` — `ecto.create` on the test repo, the alias equivalent of `createdb`.

## Conventions

- **Module key** is `"shop"` in every callback. Tab ids are prefixed
  `:admin_shop` (admin tabs) and `:admin_settings_shop` (settings tab); URL
  segments use hyphens, never underscores (`/admin/shop/shopify-sync`,
  `/admin/shop/settings/import-configs`).
- **Never hardcode a URL or path.** Build links with
  `PhoenixKit.Utils.Routes.path/1`, including cross-module links.
- **Routing.** `route_module/0` returns `PhoenixKitEcommerce.Web.Routes`,
  which emits quoted `live` declarations: `public_live_routes/0` and
  `public_live_locale_routes/0` for the storefront (spliced into core's
  unified `:phoenix_kit_public` live_session), `admin_routes/0` and
  `admin_locale_routes/0` for the admin pages that have no tab (forms,
  detail pages, settings sub-pages, the dashboard); `generate/1` emits the
  one controller route pair, the checkout claim page. Every page with a tab
  gets its route from the tab's `live_view:` instead, and must not be
  declared in `admin_routes/0` as well (two routes at one path;
  `sub_key_pages_test.exs` pins it). Never hand-register these routes in a
  host router.
- **LiveView macro** is this module's own: `use PhoenixKitEcommerce.Web,
  :live_view` (and `:live_component`), defined in `web/shop_web.ex`. It wraps
  `use Phoenix.LiveView`, injects `PhoenixKitEcommerce.Gettext` as the Gettext
  backend, and imports core's `PhoenixKitWeb.Components.Core.*` components —
  use those before hand-rolling markup. A component outside `web/` that uses
  plain `use Phoenix.Component` inherits none of it and must declare the
  Gettext backend itself.
- **Layouts.** Every public storefront page — catalog, category, product,
  cart, checkout, confirmation — renders through core's
  `LayoutWrapper.app_layout`, i.e. the HOST application's configured
  `layouts_module`, for guests and logged-in visitors alike.
  `ShopLayouts.shop_layout/1` is the single wrapper. The one exception is
  the checkout claim page (`Web.ClaimController`, `Web.ClaimHTML`): a bare
  card in the host's root layout, on purpose, because it is a hand-off page
  for a link and carries no storefront chrome. The in-page
  category/filter sidebar renders in the page templates for everyone. Admin
  LiveViews do not wrap themselves in a layout; core's admin shell supplies
  it.
- **The storefront's `<head>` tags are the host's to render.** The catalog,
  category and product pages assign `og`, `canonical_url` and
  `hreflang_links`; core's root layout reads `og` only (its canonical link
  comes from `og.url`), so `hreflang` alternates appear only when the host's
  root layout renders `hreflang_links`. `Test.Layouts.root/1` renders all
  three so a test can assert a page still supplies them.
- **Gettext** is this module's own backend (`PhoenixKitEcommerce.Gettext`,
  catalogues under `priv/gettext/{en,et,ru,de,fr,uk}`). A `gettext("…")` added
  anywhere under `web/` lands in THIS catalogue, so it needs
  `mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy` here,
  not in core. Merge with `--no-fuzzy`: fuzzy entries are live at runtime, so
  a plain merge after an extraction gap ships guessed translations.
- **Every public LiveView calls `Helpers.put_content_locale/1` (or
  `put_content_locale_from/1`) in its `mount/3`.** Core writes a dialect
  (`ru-RU`) into the process locale and this module's catalogues are plain
  codes; without the resolve step every lookup misses and the page renders
  English beside translated siblings.
- **Never wrap in `gettext`:** `push_event` names, URL paths, route segments,
  setting keys. Translating one breaks at runtime in every non-English locale.
- **A stored status is rendered through `Web.StatusLabels`** (`order/1`,
  `product/1`, `category/1`, `cart/1`, `import/1`, `translation_entry/1`),
  never as its raw value: the value keys badge classes, filters and audit
  metadata, the label is what a person reads. A new status value needs its
  own `gettext` clause there.
- **A context error is an atom or a tagged tuple with a clause in
  `Errors.message/1`**, never an English sentence: the reason is matched on
  and logged, the sentence is translated where it is shown. Each message is
  pinned in `errors_test.exs`.
- **Every public LiveView ends its `handle_event/3` clauses with the
  `Helpers.ignore_event/2` catch-all.** Anyone can push any event at a public
  page; an unknown name or a payload no clause takes must not crash the view.
- **Text stored on an order line is resolved in the locale of the process
  converting the cart** — the buyer's — and never re-translated on read.
- **JS hooks:** none. If one is ever needed, ship it as a prebuilt bundle
  declared by `js_sources/0` under a namespaced global — never registered from
  an inline `<script>`, which morphdom does not execute on LiveView
  navigation, so the hook vanishes on the first live nav.
- **CSS:** `css_sources/0` returns `[:phoenix_kit_ecommerce]` so core's CSS
  compiler adds the `@source` directive to the host's `app.css`. Without it
  Tailwind purges every class used only by this module's templates, and the
  compiler only warns when the TOTAL source list is empty, so any other
  installed module masks the absence.
- **`enabled?/0` rescues and returns `false`** — the database may not be
  available when it is asked.
- **Settings are read through their wrapper, never directly:**
  `PhoenixKitEcommerce.Policy` (security policy),
  `PhoenixKitEcommerce.Vocabulary` (catalog vocabulary),
  `PhoenixKitEcommerce.NamePrefix` (storefront name-prefix stripping),
  `PhoenixKitEcommerce.TranslationSweepSettings` (AI translations and the
  sweep), `PhoenixKitEcommerce` itself (`shipping_skip_mode/0`,
  `shipping_selection_position/0`, `notify_event?/1`,
  `enforce_product_currency?/0`, `shopify_enabled?/0`). The wrapper is the
  single source of truth for the default, so the admin UI and the enforcement
  point cannot disagree; every policy reader fails *closed* on a
  settings-layer error and tolerates a malformed stored value by falling back
  to the safe default rather than raising.
- **"Price on request" is snapshotted onto the cart line and the order line,
  never read live from the product.** A line that lost the flag formats its
  stored `unit_price` (typically `0`) and renders "0.00" where the customer
  agreed to "price on request".
- **Money is `Decimal`.** Never floats for currency.
- **Cart option validation uses the fresh product inside the pricing
  transaction.** A caller's product can predate required options or removed
  values. Both add-to-cart paths validate the same product they price;
  `skip_spec_validation: true` is the explicit trusted-caller opt-out.
- **A cart line's option selection is written and read through
  `PhoenixKitEcommerce.SelectedSpecs`, never off `selected_specs` directly.**
  On the catalogue source an option value's identity is its key (the
  attribute-set value's slug): the picker submits keys, `add_to_cart/4`
  validates and prices by key, and the line stores the key with a snapshot of
  the label the buyer saw (`metadata["selection"]`). A label is a
  translation, so two values can share one in some language. A line stored
  before keys were the identity holds labels and no snapshot; it is displayed
  as stored and never rewritten, and `SelectedSpecs.keys/2` is the only place
  it is matched back to keys. An order line carries the labels
  (`"selected_specs"`) and, for a keyed line, the keys
  (`"selected_spec_keys"`). The Legacy source is unchanged: its option values
  are admin-typed strings that are their own identity.
- **Perceptual image reuse excludes multi-frame images and preserves
  aspect ratio in the confirmation.** An identical first frame does not
  establish identical animation; stretching both inputs to a square hides
  changes to their proportions. Exact-byte reuse remains available.
- **Async work is Oban.** CSV import, image migration and the Shopify
  media/variants/collections sync run as workers, all on the single
  `shop_imports` queue — a host that configures no such queue leaves
  every job `available` forever while the UI reports "queued"; never
  spawn a bare `Task`. The exceptions: `TranslationSweepWorker`, on
  `default` beside the `PhoenixKitAI.TranslateWorker` jobs it enqueues
  (its batch and in-flight ceiling are sized against that queue, and a long
  CSV import must not hold up a tick); the search workers, on `shop_search`;
  and the three public cart API cron workers (`ApiCartSweepWorker`,
  `ApiCartPruneWorker`, `ApiClaimPruneWorker`), on `default`: they are
  short, scheduled through `oban_crons/0`, and must not wait behind an import.
  The Shopify sync runs ONE kind at a
  time: on a catalogue that does not honour `data_owned_paths`, images and
  variants each write an item's whole `data` map from a read taken when the
  run started, so two kinds together drop each other's keys (with the owned
  paths each write is limited to the paths it changed, and the rule stays
  as the cheap guard). `ShopifyMediaSyncWorker` is unique across kinds and its `perform/1`
  snoozes behind a run that started earlier; a new kind of sync joins that
  worker rather than getting a queue entry of its own.
- **Schemas:** UUIDv7 primary keys (`@primary_key {:uuid, UUIDv7,
  autogenerate: true}`, `uuid_generate_v7()` in DDL — never
  `gen_random_uuid()`), and every table-backed schema declares
  `use PhoenixKit.SchemaPrefix` so its queries target the schema core's
  migrations installed into. A conformance test enforces the second.
- **Authorization pattern.** Every admin page but the dashboard needs a
  sub-key, checked twice: core's mount gate through the tab's `permission:`
  + `live_view:` (tabbed pages only — a tab without `live_view:` maps the page
  to nothing and core falls back to the base key), and the page's own
  `Authz.authorize_mount/3` in `mount/3` (every page, tab or not). Every
  mutating admin event handler re-checks its capability through `Web.Authz`
  against the socket's current scope (fail-closed on a missing scope).
  The AI-translate modal's events are handled by `phoenix_kit_ai`'s
  `AITranslate.Embed` hook, which checks no permission, so a form using it
  declares `on_mount({Web.Authz, {:gate_ai_translate, capability}})` BEFORE
  `use ...AITranslate.Embed` (hooks run in attach order). The public `handle_event/3` clause matches the
  event name and delegates through `Authz.authorize/3` to a private
  `gated_event/3` clause holding the original body — keeping the body in its
  own clause is what stops the wrapper adding a nesting level to 47 handlers.
  Workers are authorized at ENQUEUE by the LiveView that starts them.
- **Activity logging happens at the LiveView layer**, on the `{:ok, _}` branch
  of a successful mutation, through `PhoenixKitEcommerce.Activity` — never
  inside context functions, which stay pure and keep stable signatures. The
  wrapper adds the module key (`"shop"`) and `actor_role` to core's
  `PhoenixKit.Activity.log/3`, which never raises; the actor and role come
  from `PhoenixKitWeb.Actor`.
  Rows carry no PII.
- **The core pin keeps the compound form (`>= 2.43.0 and < 3.0.0`) on
  purpose.** A three-segment `~> 2.43.0` expands to `< 2.44.0` and breaks
  CONSUMERS — a host on a newer core minor gets an unsolvable dependency set
  — while nothing in this repo's own run notices, which is why a test guards
  it. Raising the floor is fine and expected; raise it in `mix.exs` and in
  `test/core_pin_conformance_test.exs` together whenever a newly-adopted core
  or billing API needs it.
- **Assigns available in admin LiveViews:** `@phoenix_kit_current_scope`,
  `@current_locale`, `@url_path`.

### Landmines

- **Code that builds a `Product` or `Category` view-struct must set
  `origin`.** `origin` (virtual, `:legacy` by default) says where a record
  comes from and so which editor its admin Edit link opens
  (`Web.Helpers.admin_edit_path/3`): `ProductSource.Catalogue.View` sets
  `:catalogue`, and a view-struct built anywhere else without it is sent to
  the shop form, which has no such record. The link is NOT decided by the
  global `shop_product_source` switch; a catalogue record also needs the
  `"catalogue"` module key on top of `shop.manage_catalog`
  (`Web.Helpers.admin_edit_permissions/1`).
- **Every public API handler must run inside
  `API.Context.with_request_currency/2`.** The wrapper sets the process's
  request currency and the request's default language (the language of the
  domain, which may differ from the language the caller asked for). Product
  and category links are built from that default: on a mapped domain whose
  language is served without a locale prefix, a handler that skips the
  wrapper emits `/de/shop/...` links where the canonical link has no `/de/`
  segment, and the host answers each of them with a redirect. Each public
  handler has a test that checks the `url` of its items on such a domain.
  A product or category `url` goes through `API.Context.absolute/3` with the
  answer's language, which puts a language with a domain of its own on that
  domain (core's `Routes.canonical_absolute_or_nil/2`, one resolver call); `absolute/2` keeps the
  request's host.
- **One lock order for "the active cart of this identity".**
  `Shop.lock_cart_identity!/2` takes the user key, then the session key
  (`pg_advisory_xact_lock`). The claim POST, the lazy creation of an `api:`
  cart and the create path of `get_or_create_cart/1` all take it, and any new
  code that creates or claims an active cart must too. Every write to an
  `api:` cart re-checks, under the cart row lock, that the cart is still
  active and still carries the token's `session_id`, because a claim moves a
  cart without changing its status. `merge_guest_cart/2` and
  `rekey_cart_session/2` do not take the lock and never touch `api:` sessions.
  The SQL sandbox runs a test in one transaction, so a race cannot happen
  inside an ordinary test; `cart_store_race_test.exs` and
  `claims_race_test.exs` reproduce them on committed data (callers on real
  connections, or a transaction that holds the cart row while the call under
  test waits for it), and the sequential re-check is pinned beside them.
- **`API.CartWriter` and the claim's "add" merge hold a cart row and then
  call `add_to_cart`, which locks Legacy product rows** (the reverse of the
  module's product-then-cart order, see the note above `lock_active_cart!/1`).
  Lines go in product-uuid order and `deadlock_detected` is rescued (a
  retryable answer for the agent, the choice page again for the buyer); a new
  caller that locks a cart and then adds to it must do the same. The
  catalogue source locks no product rows. A rollback inside `add_to_cart`
  (`{:product_not_available, _}`, invalid specs) poisons the surrounding
  transaction, so a line is validated before the call.
- **The test harness must apply billing's migration chain, not just core's.**
  This module reads and writes billing's schemas directly, and billing owns
  `phoenix_kit_currencies` from its own V2 on, so a test database built from
  core's baseline alone is missing columns billing's `Currency` schema selects.
  The symptom is an `undefined_column` on `rounding_rule` raised from a
  currency read, hundreds of tests deep and nowhere near anything about
  currencies. `test_helper.exs` runs core's chain, then this module's,
  then billing's — and, when the catalogue path bridge is resolved,
  entities' and catalogue's. The catalogue pair matters the same way:
  core's baseline creates `phoenix_kit_cat_*` in their V1 shape, catalogue's
  own V2 adds the `slug` column its schemas insert, so a database without
  that chain fails every `:catalogue` test with `undefined_column: slug`.
- **Raising a dependency requirement means updating `mix.lock` in the same
  change.** A requirement bumped without it leaves the repo refusing to
  compile ("lock mismatch: the dependency is out of date") until someone runs
  `mix deps.get`, and the failure names the dependency rather than the commit
  that raised the floor.
- A new public page that omits `put_content_locale/1` in `mount/3` renders
  fully English while its siblings translate — the page looks correct in
  tests and inert in production. Call it, or inherit it via
  `put_content_locale_from/1`.
- Reading `price_on_request` live from the product instead of the stored line
  turns a committed "price on request" order into a "0.00" order; the product
  row is `ON DELETE SET NULL`, so deleting a product is enough to trigger it.
- A shipping method flagged `metadata["pay_on_delivery"]` (the buyer pays the
  carrier's own rates on delivery) is stored with price 0 —
  `ShippingMethod.changeset/2` forces it and clears `free_above_amount`.
  Reading that 0 as "FREE" is the bug the flag exists to prevent: ask
  `ShippingMethod.pay_on_delivery?/1` (or `present_shipping_method/2`'s
  `pay_on_delivery?`) first. Orders carry it as
  `metadata["shipping_pay_on_delivery"]` and on the shipping line as
  `"pay_on_delivery"`; read them through `PriceDisplay`
  (`line_pay_on_delivery?/1`, `order_shipping_pay_on_delivery?/1`,
  `cart_shipping_pay_on_delivery?/1`). Billing does not read the flag: its
  plain-text email prints the line as 0, and its admin order edit drops the
  key. A cart that picked a method before it was flagged keeps the old fee
  in its stored totals until `refresh_pay_on_delivery_shipping/1` (the cart
  and checkout pages call it on mount).
- `elixirc_options: [ignore_module_conflict: true]` is set for
  `compat/shop.ex` (`PhoenixKit.Modules.Shop`), and it also hides a genuine
  redefinition warning anywhere else in the package. The `compat/` namespace
  is deprecated: every delegate carries `@deprecated` naming its replacement,
  a new public function gets NO delegate there, and nothing in `lib/` or
  `test/` may call one directly (a deprecation warning fails
  `mix compile --warnings-as-errors`).
- Under `shop_shipping_selection_position: "checkout"` the cart page renders
  **no** shipping section, so redirecting a shopper to `/cart` to "pick
  another method" is a closed loop with no way out. `CheckoutPage` re-enters
  its own `:shipping` step instead.
- Every statement in the migration chain must be idempotent: `test_helper.exs`
  executes `up_statements/1` directly (no `Ecto.Migration` runner), so a
  non-idempotent statement breaks every integration run against a re-used test
  database.
- **A translation fingerprint is computed in two places and they must agree.**
  `TranslationFingerprint.hash/1` trims with `String.trim/1` (Unicode
  whitespace); the candidate SQL and the backfill task hash in Postgres, whose
  one-argument `btrim` strips only ASCII space. Every SQL hash and blankness
  test passes `sql_trim_chars/0` as `btrim`'s second argument. A divergence
  makes a row `:stale` to the sweep and `:fresh` to write-narrowing, so every
  tick pays for a model call that writes nothing — forever.
- **Shop translation only works under the Legacy product source.** Both
  adapters read the shop's own tables, and `ai_translatables/0` registers
  neither under `shop_product_source: "catalogue"`, so a `shop_*`
  `TranslateWorker` job is discarded as an unknown resource type. Anything
  new that enqueues or lists translations checks
  `PhoenixKitEcommerce.translations_supported?/0` first, as the page, the
  sweep tick and the settings toggle do.
- **`ProductForm` merges `metadata` rather than replacing it.** `cast/3` on a
  `:map` field replaces the whole map; a form that rebuilds `metadata` from
  its own inputs erases every key it renders no field for
  (`_translation_fingerprints`, `_option_slots`, `_discovered`). A new
  form-rendered top-level key belongs in `@form_owned_metadata_keys`, or it
  can never be cleared.

## Migration and testing essentials

- Never edit a shipped migration version. Add a version clause and a new
  digest in `migrations_test.exs`; shipped target digests never change.
- Every statement must be idempotent and prefix-aware. `down/1` drops no
  tables, functions or triggers; it unstamps the marker and restores V2 defaults.
  Match core's schema-specific index names. The guide documents the five
  indexes whose names include a non-public schema prefix.
- The chain is currently V6; `up/1`, `down/1` and `up_statements/2` honor the
  target version. Hosts use `mix phoenix_kit.update` / `mix phoenix_kit.status`.
- `mix test` always runs unit tests; `:integration` tests auto-skip without
  Postgres. Check the excluded count: optional dependency/API capability tags
  can hide entire feature suites. Exercise the applicable dependency builds
  when changing a guarded integration.
- The harness applies core, shop and billing migrations, plus entities and
  catalogue when resolved. Support files require an explicit entry in
  `test/test_helper.exs`. Build expected hrefs with `Routes.path/1`.
- DB environment: `PGUSER` (default `postgres`), `PGPASSWORD`, `PGHOST`,
  `PGDATABASE`, `PGPOOL`, `MIX_TEST_PARTITION`. Use the existing `DataCase` and
  `LiveCase` fixtures; race tests need committed data and real connections.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`).
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- **Remove the `compat/` namespace** (and `elixirc_options:
  [ignore_module_conflict: true]` in `mix.exs`) one release after the one
  that ships it deprecated. Core no longer references
  `PhoenixKit.Modules.Shop`; what remains is checking each host for the old
  names.
- **Add a `phoenix_kit_catalogue` floor** once a released catalogue ships the
  `PhoenixKitCatalogue.Extension` slot the duck-typed integration targets.
- **Deprecate `phoenix_kit_shop_products` / `phoenix_kit_shop_categories` and
  the two slug projections** in favour of `phoenix_kit_catalogue` once the
  storefront switches — by a host-side `COMMENT ON TABLE … 'deprecated …'`,
  never a DROP, and not part of this chain.
