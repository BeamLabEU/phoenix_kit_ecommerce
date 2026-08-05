# Follow-up: storefront layout, price units, permissions/notifications wave

## Open

### 1. Error-branch activity logging is not exhaustive

`Activity.log_failed/3` exists and the money path (order conversion) uses
it, but the admin LiveViews still log only on `{:ok, _}`. The quality-sweep
playbook wants both branches everywhere (a run of failed deletes is what an
operator most wants to see). ~24 call sites; mechanical but wide.

### 2. `Translations.default_language/0` can disagree with the slug resolver

`SlugResolver` normalizes a base code to its dialect (`"en"` → `"en-US"`)
before looking a slug up, while `Translations.default_language/0` may
return the bare base code. When a shop's default IS a bare base code, a
localized map keyed by `default_language/0` cannot be found by the
resolver — `upsert_product/1` then fails to match its own slug and tries to
INSERT, hitting the unique index. Surfaced by a test that had to key its
fixtures through `normalize_language_public/1` to exercise the production
path. Worth collapsing the two onto one resolution rule.

### 3. The disabled-shop gate does not reach already-connected sessions

Mount redirects and the context refuses purchases, so nothing can be
BOUGHT while disabled. But a shopper whose page was already open keeps
filtering, paginating and mutating their cart: no disable event is
broadcast, and no `handle_event` re-checks. Closing it means broadcasting
a module-disabled event and handling it in the storefront LiveViews.

### 4. `assign_cart_state/2` is not idempotent under PubSub echo

The cart page's choke point runs again when the LiveView receives its own
broadcast. Clearing an outgrown shipping method twice is harmless today,
but `clear_cart_shipping/1` has no conditional update, so a late echo can
clear a selection another tab made in between. Wants an optimistic guard
(only clear when the method is still the one that was ineligible).

### 5. Product deletion is broadcast on the global topic only

The product page subscribes per-product and to inventory, so a delete (or
a bulk delete, which broadcasts nothing) never reaches the open page. The
new "product vanished" redirect in `refresh_product/1` therefore cannot
fire for deletion — the shopper finds out by clicking Add to Cart. Wants
`Events.broadcast_product_deleted/1` to also publish on the per-product
topic.

### 6. Storefront i18n remains incomplete

The public LiveViews still carry hardcoded English ("Welcome to Our Shop",
"Product not found", flash copy). The new strings this wave added ARE
extracted and translated (ru/et); the pre-existing ones are not.

### 7. Leftover assigns

`authenticated` and `current_path` are still computed in the five shopping
LiveViews although no template consumes them since the layout unification.
Harmless, deletable.

## Cross-repo

### billing: `maybe_update_billing_snapshot` re-snapshot policy

Now operator-configurable (`billing_snapshot_policy`: `pending_only`
default / `never` / `always`) — see the billing wave. The ecommerce side
(order pages prefer `order.billing_snapshot`) is correct under any setting.
