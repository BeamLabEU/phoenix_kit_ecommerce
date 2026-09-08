# Storefront: price display and i18n

How a price is written on each storefront surface, and what has to be true for a
storefront string to reach a shopper translated.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Conventions.

## Price display (units, "From", and price on request)

`PhoenixKitEcommerce.PriceDisplay` owns how a price is WRITTEN: an optional
per-language unit ("per hour", "per m²", "в час"), an optional "From"
prefix, and an optional "price on request" flag, stored under one reserved
metadata namespace `Product.metadata["_price_display"]` =
`%{"unit" => %{lang => text}, "from" => bool, "on_request" => bool}`. Free
text, not a unit vocabulary — every shop invents units the next one has
never heard of.

`"on_request"` is written **only when true**, so `build/2` produces exactly
the map it always did and an existing product does not gain a key on its
next save; `settings/1` reads a missing key as `false`.

`render/4` takes an explicit CONTEXT because the same product means
different things per page:

- `:catalog` — the asking price; may show "From" (explicit flag OR a real
  option range) and derives the amount from the option-aware range
- `:selected` — the price for the chosen options; exact, never "From"
- `:cart` / `:order` — a SNAPSHOT; exact, never "From", and the unit comes
  from the stored line, never the live product, so an edit or deletion
  cannot relabel what a customer already agreed to

**"Price on request" must be SNAPSHOTTED onto the line, not read live.**
`CartItem.from_product/3` writes `metadata["price_on_request"]` beside
`price_unit`, and `convert_cart_to_order/2` forwards it into the order's
line items. The flag only suppresses a number that still exists on the
product, so a line that lost it falls back to formatting its stored
`unit_price` — typically `0` — and renders "0.00" where the customer agreed
to "price on request": free, on a committed order. `product_uuid` is
`ON DELETE SET NULL`, so this is reachable simply by deleting a product. A
regression test covers both the cart line and the order line; keep it.

Two paths would silently erase an admin's settings and are guarded: the
CSV upsert (`merge_localized_attrs/2` replaces metadata wholesale) and the
product form (its metadata build replaces too, so the inputs are real form
fields). Absent settings render exactly what the module rendered before.

## Storefront i18n contract

Two things must both be true for a storefront string to appear translated,
and each has failed independently:

1. **The string is wrapped.** A public file carrying zero `gettext` calls
   beside siblings that are fully translated makes a trilingual shop render
   its product content in Estonian inside an entirely English frame. Flash
   messages and `page_title` count — they are as visible to a customer as
   anything in the markup.
2. **The backend is pointed at a locale the catalogue HAS.** The content
   language is a DIALECT (`resolve_dialect/1` returns `"ru-RU"`, `"et-EE"`,
   `"en-US"`) and core writes that into the process locale, but this module
   ships `priv/gettext/{en,et,ru,de,fr}` — plain codes. **Gettext does not
   fall back from `ru-RU` to `ru`**, so every lookup misses and returns its
   msgid, which is the English source string. `Helpers.put_content_locale/1`
   resolves the dialect against the backend's known locales and is called
   from `mount/3`, which runs once per process for both the dead render and
   the connected mount. An unsupported locale RESETS to the shop's
   configured default rather than no-op: `put_locale/2` is process-scoped
   and a keep-alive connection process is reused across requests, so a
   no-op would serve the previous request's locale to the next visitor.

⚠️ A page can be fully translated and completely inert at the same time.
When adding a public page, call `put_content_locale/1` in its `mount/3` or
it will render English while its siblings translate.

`catalog_sidebar.ex` is `use Phoenix.Component`, not the module's own web
macros, so it does NOT inherit the Gettext backend those inject and declares
one explicitly. Any new component outside `web/` must do the same.

Strings that must NEVER be wrapped: `push_event` names, URL paths, route
segments, setting keys. Two of these were wrapped once and would have broken
at runtime in every non-English locale.
