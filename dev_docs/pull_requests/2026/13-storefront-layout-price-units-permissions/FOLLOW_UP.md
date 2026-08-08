# Follow-up: storefront layout, price units, permissions/notifications wave

## Open

### 1. Error-branch activity logging is not exhaustive

`Activity.log_failed/3` exists and the money path (order conversion) uses
it, but the admin LiveViews still log only on `{:ok, _}`. The quality-sweep
playbook wants both branches everywhere (a run of failed deletes is what an
operator most wants to see). ~24 call sites; mechanical but wide.

### 2. ~~`Translations.default_language/0` can disagree with the slug resolver~~ FIXED

Every lookup now matches any spelling of the same language rather than
insisting on the normalized one, so a shop whose language is the base code
resolves its own slugs. The two resolution rules still exist; collapsing
them onto one remains worthwhile, but nothing is broken by the difference.

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

### 8. The imported option model cannot express a variant matrix

An adversarial sweep of the import subsystem confirmed four related limits
in how Shopify variants become options. They share one cause — options are
stored as INDEPENDENT lists with per-value price modifiers, while a Shopify
feed describes a matrix of specific combinations — so they want a design
decision, not a patch:

  * **Modifiers are summed, so real combinations are mispriced.** `S/Red
    10.00` + `L/Blue 18.00` yields `L => +8` and `Blue => +8`; picking the
    real `L/Blue` charges 26. The pair `S/Blue`, which the feed never
    offered, is also selectable and add-to-cart accepts it (each option is
    validated independently).
  * **The no-mapping path drops Option3–Option10** and gives Option2 no
    price impact at all, so a mapped-away material disappears and a
    pricier colour charges the base price.
  * **`_option_slots` is written but the storefront reads the non-slot
    schema**, so a product can show both the discovered per-product option
    and the global one it was mapped to — including values this product
    never offered.
  * **A global `multiselect` prices as a single value.** `multiselect` is
    declared price-capable and validation accepts a list, but pricing reads
    only a binary selected value, so a list gets a zero modifier.

Storing the CSV's combinations (a variant table with its own price) is the
real fix; per-value modifiers can then be derived for display.

### 9. `Money.parse/1` reshapes two plausible inputs

Confirmed by the same sweep, both narrow:

  * `($1,234.56)` — accounting notation for a negative — parses as a
    POSITIVE 1234.56 rather than being rejected or negated.
  * `1.2e3` parses as `1.23`, because the strip removes `e` before the
    separator logic runs.

Neither shape appears in a Shopify or Prom.ua export, which is why this is
recorded rather than fixed. A three-decimal currency is the same story: a
lone three-digit tail (`1.234`) is deliberately read as thousands grouping.

### 10. Regional dialects of one language still do not cross-match

`language_keys/1` expands a code to itself, its dialect and its base — so
`"en"` and `"en-US"` find each other, but a product keyed `"en-GB"` is not
found by an `"en-US"` request. Closing it properly means matching on the
key's base rather than an enumerated candidate list (a `jsonb_each_text`
predicate), which is a scan; today's lookups are a scan anyway (no shipped
index answers `slug->>? = ?`), so this is affordable — it just wants
measuring on a real catalogue first.

### 11. A handle-less feed cannot be matched on re-import

A Shopify row with no Handle now imports as its own product with a slug
derived from its title, but nothing carries that identity back into the
next import: `upsert_product/1` matches on the incoming slug map, which a
handle-less group does not have. A second import of the same file inserts
again (the primary-slug unique index turns that into a reported row error
rather than a duplicate). The validator already warns about blank handles;
worth deciding whether the transformer should derive the slug up front so
the match works, accepting that it then collides with a real handle of the
same name.

## Cross-repo

### billing: `maybe_update_billing_snapshot` re-snapshot policy

Now operator-configurable (`billing_snapshot_policy`: `pending_only`
default / `never` / `always`) — see the billing wave. The ecommerce side
(order pages prefer `order.billing_snapshot`) is correct under any setting.
