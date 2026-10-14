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
  # `PhoenixKit.API.Tool` ships with the core that carries the shop API; a
  # released core older than that has no `Tool.new/1`, and the public tools are
  # simply not offered there. `@compile {:no_warn_undefined, ...}` silences the
  # compiler's xref but not dialyzer. Drop this line once the minimum core
  # requirement in mix.exs carries `PhoenixKit.API.Tool`.
  {"lib/phoenix_kit_ecommerce/api/public_tools.ex", :unknown_function},
  # The cart store names `PhoenixKit.API.RateLimit` too (same reason).
  {"lib/phoenix_kit_ecommerce/api/cart_store.ex", :unknown_function},
  # `PhoenixKitWebAnalytics.Config` is an optional dependency: the claim-path
  # exclusion step of the migration reads its default list when it is loaded.
  {"lib/phoenix_kit_ecommerce/migrations.ex", :unknown_function},
  # The claim page marks itself with `PhoenixKitWebAnalytics.Plug.skip/1` when
  # that optional dependency is loaded.
  {"lib/phoenix_kit_ecommerce/web/claim_controller.ex", :unknown_function}
]
