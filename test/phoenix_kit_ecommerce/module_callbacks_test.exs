defmodule PhoenixKitEcommerce.ModuleCallbacksTest do
  @moduledoc """
  Pins the `PhoenixKit.Module` callbacks this module contributes to its host.

  These exist because `css_sources/0` was documented in both README.md and
  AGENTS.md as implemented, and was not. The failure was invisible: core's
  `:phoenix_kit_css_sources` compiler collects the callback from every
  discovered module, and only warns when the TOTAL list is empty — so any
  other installed module masked the absence, while Tailwind quietly purged
  every class used only by this module's templates from the host build.

  A one-line assertion would have caught it, so here is the one line.
  """
  use ExUnit.Case, async: true

  test "css_sources/0 contributes this app to the host Tailwind build" do
    assert PhoenixKitEcommerce.css_sources() == [:phoenix_kit_ecommerce]
  end

  test "module_key/0 matches what the permission and tabs declare" do
    # `permission: "shop"` on every tab, and `has_module_access?(scope, "shop")`
    # in the admin LiveViews, are all the same string as this. If it drifts,
    # every permission check silently starts asking about a module that does
    # not exist.
    assert PhoenixKitEcommerce.module_key() == "shop"

    for tab <- PhoenixKitEcommerce.admin_tabs() do
      assert tab.permission == "shop", "tab #{inspect(tab.id)} guards the wrong key"
    end
  end

  test "required_modules/0 names billing, which this module hard-depends on" do
    # Order and invoice creation route through PhoenixKitBilling; declaring it
    # is what stops a host enabling shop without it.
    assert "billing" in PhoenixKitEcommerce.required_modules()
  end

  test "version/0 reports the app version rather than a placeholder" do
    refute PhoenixKitEcommerce.version() == "0.0.0"
  end
end
