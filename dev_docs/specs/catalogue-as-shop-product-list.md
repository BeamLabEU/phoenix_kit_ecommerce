# Catalogue as the shop's product list

Designed 2026-09-05. Rewritten 2026-11-06 against the code: ecommerce 0.9.0,
catalogue 0.50.0, entities 0.7.0, core 3.3.0.

Code comments cite this file by block ("Block 3", "sync 6a"), by section and by
principle ("§2 principle 8", "§4 row C4"), so those numbers stay fixed. Where the
code took a different path from the first design, this file describes the code.

## Decision

The shop stops owning a catalogue. Products, categories, attributes and their
translations live in `phoenix_kit_catalogue`, with attributes as sets on
`phoenix_kit_entities`. Shop fields live inside the catalogue's JSONB
(`item.data`, `category.data`), not in ecommerce tables.
`phoenix_kit_ecommerce` keeps the cart, checkout, orders and storefront
rendering. Where a host sells through Shopify, Shopify is the master and the
catalogue mirrors it.

No table is dropped. A host that switches marks the shop's product tables
deprecated with a comment. Legacy stays a supported source until a release says
otherwise (§8).

## 0. Status

The architecture is in place and one host runs on it. A second host cannot
follow yet, because the switch and the data migration exist only in that first
host's own mix tasks (§6).

| Block | Subject | Status |
|---|---|---|
| 0 | Module migration chains | Done |
| 1 | Catalogue extensions, form slot | Partial: three shop fields have no form input |
| 2 | Data migration | Done for the first host, not in this library |
| 3 | `ProductSource`, storefront, Shopify sync 6a | Done |
| 4 | Categories on the storefront | Partial: category SEO unused, no filter inheritance |
| 5 | Attribute picker and filters | Partial: `disabled_value_slugs` unused, draft values offered |
| 6 | Translations | Done, on the catalogue's side |
| 7 | Shopify 6b: images, variants, collections | Done, except the handle fallback in `CollectionSync` |
| 8 | Tags and core follow-ups | Partial: tags done, core sitemap and doctor left as they are |

Work this design did not cover was built on the Catalogue source afterwards: the
search index, the public and admin APIs, stock limits and order emails.

### Open work

- Define what makes an item listed. Today an item with no price sells at 0.00, an
  item with no slug links to `/shop/product/`, and saving the catalogue form on an
  item with no `shop_status` unpublishes it (§2 principles 5 and 7).
- Move the source switch and the data migration into this library (§6).
- Close the feature gaps between the sources, or retire Legacy (§8).
- Use a category's `_seo_title` and `_seo_description` on the storefront. They are
  stored and translated, but `SeoHelpers.category_seo/2` reads neither and
  `View.category_view/2` does not carry them.
- Give `price_modifiers`, `storefront_filters` and `option_schema` a form input
  (`ShopSections`), or settle that the Shopify sync and direct API writes are
  their only writers.
- Honour `disabled_value_slugs` in the picker, or remove it from the design.
- Filter draft values out of a set's explicit selection in the picker. Only the
  whole-set case filters them today.
- Add the `product_id` to handle fallback to `CollectionSync`, as the media
  worker has.
- Add a unique index on entities `(entity_uuid, slug)`. It is an accepted gap
  today (`PhoenixKitEntities.Managed`).

## 1. Starting point

In September 2026 the shop's own tables were the only source for the storefront,
cart and sitemap. Attributes were English strings in `metadata._option_values`,
with no dictionary and no translations. The Shopify sync wrote seven fields into
`shop_products`, keyed by handle, and created nothing new. Catalogue 0.26 had
items, a category tree, attribute sets and AI translation, but no public URL,
slug, SEO fields, `compare_at_price`, currency or form slot for another module's
fields. Other projects use the catalogue too, so every change to it had to be
additive and opt-in.

## 2. Target architecture

```
Shopify (master, where the host uses it)
   │ one-way sync: fields, compare_at, new products (Block 3);
   │               images, variants, collections (Block 7)
   ▼
phoenix_kit_catalogue  = items, categories, attribute sets (on entities),
   │                     translations, slugs and SEO, shop fields in data["ecommerce"]
   │ read through ProductSource.Catalogue
   ▼
phoenix_kit_ecommerce  = storefront, cart, checkout, orders, Shopify sync,
   │                     the Shop section of the catalogue's forms
   ▼
shopper: URLs, sitemap, hreflang and old-slug redirects unchanged
```

Principles:

1. **Catalogue is the one source of content and shop fields.** True for a host on
   the Catalogue source. `ProductSource.current/0` falls back to Legacy, which is
   still the default, and this chain still creates both tables.
2. **Shop fields live in `item.data["ecommerce"]` and `category.data["ecommerce"]`.**
   `Catalogue.ItemCommerce` and `Catalogue.CategoryCommerce` are the embedded
   schemas that define and validate them. The moduledocs hold the field lists,
   which grew well past the first design: `cost_per_item`, parcel dimensions,
   `price_fit_rule`, related-product lists and `legacy_metadata`.
   `digital_files` became `file_uuid` and `download_*`. A category's `hidden` flag
   became `shop_status` (`active`, `unlisted`, `hidden`), and its picture is the
   catalogue's own `data["featured_image_uuid"]`. Translation fingerprints sit in
   `data["_translation_fingerprints"]`, outside the namespace.
3. **SEO lives in the catalogue's multilang data.** `_seo_title` and
   `_seo_description` are per-language override keys beside `_name` and
   `_description`. The slug is a flat `slug jsonb` column (language to value) on
   items and categories. Both are generic catalogue features, not shop ones.
4. **Slugs are unique per language** through the trigger projections
   `phoenix_kit_cat_item_slugs` and `phoenix_kit_cat_category_slugs`, primary key
   `(lang, value)`, across all catalogues.
5. **Price is `item.base_price`.** The view reads it directly and never calls
   `Item.final_price/3`, so a markup or discount set on the catalogue side has no
   effect in the shop. The Shopify writer keeps `markup_percentage` at 0.
6. **Attributes are catalogue attribute sets**: a blueprint in entities, with
   values as entity data. An item keeps its choice in
   `item_attribute_sets.data.selected_value_slugs`, one row per item and set. An
   empty selection means the whole set applies, which the first design did not
   cover: the picker offers every published value, and filters and facets skip
   the item.
7. **An item is visible in the shop** when `item.status` is `active` and
   `data.ecommerce.shop_status` is `active`. A missing `shop_status` reads as
   `active`, although `ItemCommerce`, the form and the API default to `draft`. So
   an item never saved with the extension shows in the shop, and the first save
   of it on the catalogue form stores `draft` and takes it down.
8. **The catalogue's forms have an extension slot.** `PhoenixKitCatalogue.Extension`
   requires `key/0` and `enabled?/0`. `item_section/1`, `category_section/1`,
   `cast_item/2`, `cast_category/2`, `item_columns/0`, `category_columns/0` and
   `duplicate_data/2` are optional. Discovery goes through
   `PhoenixKit.ModuleRegistry` and `catalogue_extensions/0`, so the catalogue never
   names the shop.
9. **The storefront stays in ecommerce and reads through `ProductSource`.** There
   are two adapters, not the single one first planned. `ProductSource.Catalogue`
   returns hand-built `%Product{}` and `%Category{}` view-structs, so the facade,
   guards, `CartItem`, `Options` and the sitemap need no rewrite.
   `update_product/2` and `delete_product/2` refuse a view-struct with
   `{:error, :read_only_view}`.
10. **Deleting a catalogue item is not blocked.** A cart line survives and an order
    is a snapshot. A catalogue cart line keeps its item in
    `metadata["catalogue_item_uuid"]`, and its `product_uuid` is nil.
11. **Categories are the main extension.** Hierarchy, order and names stay in the
    catalogue, and the shop adds status, filters, option schema and the featured
    item.

## 3. Migrations

Each module owns a chain: catalogue at V6, this module at V6, entities at V1. The
first design planned one consolidated V01 per module, and later versions replaced
that plan. Hosts run them with `mix phoenix_kit.update`. The version marker is a
`COMMENT ON TABLE`, every statement is idempotent, and `down/1` drops no table.

| Chain | Owns |
|---|---|
| Catalogue | 18 adopted `phoenix_kit_cat_*` tables, the two slug projections from V2 and `item_dependencies` from V6: 21 in all |
| Entities | `phoenix_kit_entities`, `phoenix_kit_entity_data` |
| Ecommerce | The 10 `phoenix_kit_shop_*` tables with their slug projections, then the search index (V4) and cart claims (V5) |

Core 3.0 stopped creating module tables, so these chains build them where they do
not exist and adopt them where they do. Core 3.x needs a database at V225 or later
before it upgrades. It dropped no tables.

`phoenix_kit_shop_products`, `phoenix_kit_shop_categories` and both slug
projections stay in place. A host that switches marks them deprecated in a
migration of its own (§6).

## 4. Module changes

Catalogue. Every change was additive; the drag-and-drop tree, attribute sets, PDFs
and suppliers were not touched.

| # | Change | Status |
|---|---|---|
| C1 | `migrations.ex` and `migration_module/0` | Done |
| C2 | Generic slug and SEO, slug projections, `get_item_by_slug/3`, `get_category_by_slug/3` | Done. The slug rule lives in `Catalogue.Slugs`, outside the changesets |
| C3 | Catalogue sitemap source and `UrlResolver` | Dropped. Core's shop sitemap source reads through the facade |
| C4 | Extension slot on the item and category forms | Done |
| C5 | `data["ecommerce"]` stays opaque to the catalogue | Partial. The forms leave it alone, but the catalogue's API reads it and writes `shop_status`, and its file references read it |
| C6 | `Attachments.attach_files/3` without a LiveView | Done |
| C7 | AI adapter: SEO and summary fields, set resources | Done, except `_slug`: a slug is derived from the translated name |
| C8 | `Item.status`, `base_price` and markups unchanged | Done |

Entities gained its chain; the unique index on `(entity_uuid, slug)` is open (§0).
Ecommerce gained its chain, `ProductSource`, `ItemCommerce`, `CategoryCommerce`,
the slot and the sync. Core's Storage orphan check became each module's
`file_references/0`.

## 5. Blocks

### Block 0. Module migrations

The chains, their `up_statements` tests and the host wrappers. Done (§3).

### Block 1. Catalogue extensions

C2, C4 and C6, plus `ItemCommerce`, `CategoryCommerce` and the Shop section of the
forms. `price_modifiers`, `storefront_filters` and `option_schema` have no input
there (`ShopSections`).

### Block 2. Data migration

Copies categories, products, option values and images into the catalogue, with
`data.ecommerce.legacy_product_uuid` as the idempotency key. The shop tables are
only read. It has a dry run, a report and a rollback. It is a mix task of the first
host, not of this library (§6).

### Block 3. ProductSource, storefront, sync 6a

`ProductSource` and its adapters; the facade delegates to them. Under the Catalogue
source the Shopify sync writes through `Catalogue.Writer`, keyed by
`data.ecommerce.shopify.handle`, and creates new products. CSV import and the shop's
translation adapters are off, and the product and category forms hand over to
`/admin/catalogues`.

The source is the `shop_product_source` key in `phoenix_kit_shop_config`. The
catalogue is the `shop_catalogue` key, which holds its name and has no default.
No function of this package writes either.

### Block 4. Categories on the storefront

Navigation, category pages and cross-language redirects run on catalogue categories.
`storefront_filters` overrides the global filters per category, with no inheritance
from a parent. Category order is the catalogue's order.

### Block 5. Attributes, picker, filters

The picker builds from an item's sets, with labels per language. The `attribute_set`
filter counts values with its own query and uses the GIN index on
`selected_value_slugs`. `ValueResolver` maps a Shopify label to a value slug and
creates a `draft` value when none matches. Price modifiers come from
`data["ecommerce"]["price_modifiers"]`. `metadata_option` filters stayed, as an alias
of `attribute_set`.

### Block 6. Translations

Lives in the catalogue: its adapters, the page at `/admin/catalogues/translations`,
per-field fingerprints and an opt-in sweep. The shop's own translation control stays
Legacy-only (`translations_supported?/0`).

### Block 7. Shopify 6b

`CollectionSync` maps collections onto categories and keeps their order, with an
allowlist (`shopify_collections_filter`) and the narrowest collection winning for an
item in several. `ShopifyMediaSyncWorker` runs images, variants and collections one
kind at a time. Item order comes from the collection products endpoint. Images are
reused by URL, then by hash and fingerprint.

### Block 8. Tags and core

Tags live in `data["ecommerce"]["tags"]`, and their badges show in the default
language only. Descriptions are normalised from HTML to Markdown on the write path.
Core's doctor list and sitemap stay as they are: the sitemap reads through the
facade, and the catalogue's tables are left out of the doctor on purpose. The vendor
filter is wired and off by default, with no decision on it yet.

## 6. Moving a host to the catalogue source

The first host did this with its own mix tasks. Nothing here does it for a second
host yet. The steps are:

1. Add the optional `phoenix_kit_catalogue` and `phoenix_kit_entities` dependencies,
   enable both modules and run `mix phoenix_kit.update`.
2. Create the shop's catalogue.
3. Copy the shop tables into it (Block 2) and read the report.
4. Back up the database and take a sitemap snapshot.
5. Compare the counts: items and products, categories, both slug projections.
6. Write `shop_catalogue` and then `shop_product_source` to `phoenix_kit_shop_config`.
   Each value is stored as `%{"value" => value}`.
7. Rebuild the search index, and mark the four shop tables deprecated.

Order matters in step 6: `shop_product_source` set first, with no `shop_catalogue`,
gives an empty storefront until the second key lands.

## 7. Risks and rollback

- Before the switch, rollback is complete. After it, the shop tables stop receiving
  changes, so going back loses whatever was edited in the catalogue.
- `shop_catalogue` unset or wrong means an empty storefront and a logged warning. The
  shop never picks a catalogue by itself, because creating an unrelated catalogue
  must not change what it sells.
- A catalogue version below the floor is refused at dependency resolution. The admin
  API also checks what the loaded catalogue exports, because a fork keeps the version
  of its base (`API.Gate.catalogue_api_ready?/0`).

## 8. Decisions and open questions

Settled:

- Sets repeat the source attributes one to one, rare keys included. Only technical
  duplicates of a key are merged automatically.
- No table is dropped by this project, only described.
- Shopify collections become catalogue categories with their order kept.
- Tags are kept, and hidden on non-default languages until they are translated.
- Translation belongs to the catalogue, not to `data["ecommerce"]`.

Open:

- Does Legacy stay a long-term source, or does it get a retirement date? Every new
  feature currently picks a side, and neither source has them all.
- Should the library own the switch and the data migration (§6)?
- Should a missing `shop_status` keep reading as `active` (§2 principle 7)?
- Should the vendor filter be on?
