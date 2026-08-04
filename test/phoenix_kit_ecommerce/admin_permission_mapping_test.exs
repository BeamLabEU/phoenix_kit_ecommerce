defmodule PhoenixKitEcommerce.AdminPermissionMappingTest do
  @moduledoc """
  Pins the inputs to the contract that gates every shop admin page.

  ## What gates these pages

  Core's `live_session :phoenix_kit_admin` runs
  `PhoenixKitWeb.Users.Auth :phoenix_kit_ensure_admin`. That hook does NOT
  stop at `can_access_admin_area?/1` — which is true for any permission
  holder — it goes on to resolve a permission key for the mounted view and
  requires `Scope.has_module_access?(scope, key)`.

  For this module the resolution is entirely IMPLICIT. Core takes the
  view's top-level namespace, asks `ModuleRegistry` which module owns it,
  and calls that module's `module_key/0`:

      PhoenixKitEcommerce.Web.Products
        |> Module.split() |> hd()          # "PhoenixKitEcommerce"
        |> ModuleRegistry.get_module_key_for_namespace()
        |> # -> PhoenixKitEcommerce.module_key() -> "shop"

  Verified in a real host app: every shop admin view resolves to `"shop"`,
  and a user holding only an unrelated permission is halted at mount, so no
  LiveView process is ever created and there are no events to drive.

  ## Why this test exists

  Nothing asserted any of that. The security property rests on a namespace
  string and a callback consumed by *another package's* inference chain —
  rename the namespace, drop `module_key/0`, or reorder core's resolution
  layers, and every shop admin page silently loosens with no test failing.

  ## What this test can and cannot do

  It CANNOT call core's resolver end to end: `ModuleRegistry` is a
  GenServer a host app starts and populates by beam discovery at boot, and
  this repo's test env has no host, so the registry is absent and every
  lookup returns nil. (Nil is fail-closed in core — it demands
  `holds_all_enabled_permissions?/1` — so the absence is safe, but it makes
  an end-to-end assertion here vacuous rather than meaningful.)

  So it pins the two INPUTS the inference consumes, both of which are real
  drift risks and both testable from here, plus the denial semantics of the
  check they feed. A host-app test is the right home for the end-to-end
  assertion; this is the tripwire for the half that lives in this repo.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.Scope

  @admin_views [
    PhoenixKitEcommerce.Web.Dashboard,
    PhoenixKitEcommerce.Web.Products,
    PhoenixKitEcommerce.Web.ProductForm,
    PhoenixKitEcommerce.Web.ProductDetail,
    PhoenixKitEcommerce.Web.Categories,
    PhoenixKitEcommerce.Web.CategoryForm,
    PhoenixKitEcommerce.Web.ShippingMethods,
    PhoenixKitEcommerce.Web.ShippingMethodForm,
    PhoenixKitEcommerce.Web.Carts,
    PhoenixKitEcommerce.Web.Settings,
    PhoenixKitEcommerce.Web.OptionsSettings,
    PhoenixKitEcommerce.Web.Imports,
    PhoenixKitEcommerce.Web.ImportShow,
    PhoenixKitEcommerce.Web.ImportConfigs
  ]

  test "module_key/0 is the exact string the admin gate resolves to" do
    # Core's inference ends at this call. It is also the string every tab's
    # `permission:` and every `has_module_access?/2` call uses.
    assert PhoenixKitEcommerce.module_key() == "shop"
  end

  test "every admin LiveView sits under the namespace core infers from" do
    # `infer_permission_key_from_module/1` uses `Module.split |> hd`. An
    # admin page moved outside this namespace stops resolving to "shop" and
    # falls back to the unmapped branch, which requires EVERY permission —
    # so a legitimate shop admin would lose access, silently, and only in
    # production where the registry is actually populated.
    for view <- @admin_views do
      assert view |> Module.split() |> hd() == "PhoenixKitEcommerce",
             "#{inspect(view)} is outside the namespace core infers the permission key from"

      assert Code.ensure_loaded?(view), "#{inspect(view)} does not exist"
    end
  end

  test "every admin tab guards the same key the namespace resolves to" do
    # If a tab's `permission:` and `module_key/0` drift apart, the sidebar
    # and the actual gate disagree: the page hides but stays reachable, or
    # shows and then denies.
    for tab <- PhoenixKitEcommerce.admin_tabs() do
      assert tab.permission == PhoenixKitEcommerce.module_key(),
             "tab #{inspect(tab.id)} guards #{inspect(tab.permission)}"
    end
  end

  describe "the check the resolved key feeds" do
    test "a holder of an unrelated permission is denied" do
      unrelated = %Scope{user: %{uuid: "u1"}, cached_permissions: MapSet.new(["dashboard"])}
      refute Scope.has_module_access?(unrelated, "shop")
    end

    test "a holder of the shop permission is allowed" do
      shop = %Scope{user: %{uuid: "u2"}, cached_permissions: MapSet.new(["shop"])}
      assert Scope.has_module_access?(shop, "shop")
    end

    test "a user with no permissions is denied" do
      none = %Scope{user: %{uuid: "u3"}, cached_permissions: MapSet.new([])}
      refute Scope.has_module_access?(none, "shop")
    end

    test "roles alone do not grant module access — only permissions do" do
      # `has_module_access?/2` reads cached_permissions (plus the "*"
      # superadmin key). A scope carrying an Owner ROLE but no permissions
      # does not pass here; Owner works in production because it holds every
      # key by construction, not because the role is special.
      role_only = %Scope{
        user: %{uuid: "u4"},
        authenticated?: true,
        cached_roles: ["Owner"],
        cached_permissions: MapSet.new([])
      }

      refute Scope.has_module_access?(role_only, "shop")
    end
  end
end
