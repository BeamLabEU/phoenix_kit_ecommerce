[
  # Gettext.Backend expands into code that constructs %Expo.PluralForms{}
  # literals inline; that struct is @opaque in Expo, so dialyzer flags the
  # generated call to Gettext.Plural.plural/2 as a call_without_opaque
  # mismatch. Known upstream false positive (gettext >= 0.26) — the plural
  # forms work correctly. (Surfaced once et/ru plural translations were added,
  # which is when the backend emits the plural code path. Mirrors the same
  # ignore in phoenix_kit_staff / phoenix_kit_billing / phoenix_kit_catalogue
  # / phoenix_kit_projects.)
  {"lib/phoenix_kit_ecommerce/gettext.ex", :call_without_opaque},
  # The admin API's e-commerce tools call core's tool registry and API config
  # (`PhoenixKit.API.Tool`, `PhoenixKit.API.Config`, used by settings.ex) and the
  # catalogue's admin API (`PhoenixKitCatalogue.API.resolve_refs/2`,
  # `Catalogue.update_items/2`), which no released core or catalogue ships yet.
  # Dialyzer reports a missing module as `:unknown_function` and a missing
  # function of a loaded module (`Catalogue.update_items/2`) as `:call_to_missing`.
  # Remove these entries when a released core and catalogue ship the API: they
  # then become "unnecessary skips" and fail `mix precommit`.
  {"lib/phoenix_kit_ecommerce/api.ex", :unknown_function},
  {"lib/phoenix_kit_ecommerce/api/refs.ex", :unknown_function},
  {"lib/phoenix_kit_ecommerce/api/catalogue_writes.ex", :call_to_missing},
  {"lib/phoenix_kit_ecommerce/api/settings.ex", :unknown_function}
]
