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
  # Scope.for_user/2 constructs cached_permissions as a MapSet; Dialyzer
  # infers its concrete internals and cannot reconcile them with the opaque
  # MapSet in Scope.can?/2's Scope.t() contract. Core suppresses the same
  # mismatch in its own Scope.for_user callers. Keep the live permission check.
  {"lib/phoenix_kit_ecommerce/api/gate.ex", :call_without_opaque},
  # `PhoenixKitWebAnalytics.Config` is an optional dependency: the claim-path
  # exclusion step of the migration reads its default list when it is loaded.
  {"lib/phoenix_kit_ecommerce/migrations.ex",
   "Function PhoenixKitWebAnalytics.Config.default_exclusions/0 does not exist."},
  # The claim page marks itself with `PhoenixKitWebAnalytics.Plug.skip/1` when
  # that optional dependency is loaded.
  {"lib/phoenix_kit_ecommerce/web/claim_controller.ex",
   "Function PhoenixKitWebAnalytics.Plug.skip/1 does not exist."}
]
