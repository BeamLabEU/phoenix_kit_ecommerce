defmodule PhoenixKitEcommerce.Web.Components.ShopLayouts do
  @moduledoc """
  Shared layout wrapper for the shop storefront public pages.

  `shop_layout/1` renders every storefront page — catalog, category, product,
  cart, checkout, confirmation — inside core's
  `PhoenixKitWeb.Components.LayoutWrapper.app_layout`, which resolves the host
  application's configured `layouts_module`. The storefront therefore always
  looks like part of the host site, for guests and authenticated users alike.

  History: until 2026-08 this module dispatched between three layouts — a
  self-contained `shop_public_layout` for guest catalog pages (which bypassed
  the host layout entirely), the admin dashboard layout for any authenticated
  visitor, and `app_layout` for guest cart/checkout. The first two paths were
  the subject of a host-app bug report (the storefront did not look like the
  host site) and were removed; the in-page category/filter sidebar that the
  dashboard layout used to carry now renders in the page templates for
  everyone.
  """

  use Phoenix.Component

  @doc """
  Top-level layout wrapper for shop storefront pages.

  Always renders through core's `LayoutWrapper.app_layout`, honouring the
  host's `layouts_module` configuration.
  """
  slot :inner_block, required: true
  attr :flash, :map, required: true
  # nil-tolerant: core's public live_session always assigns a scope, but a
  # host mounting a storefront LV outside that session must degrade to the
  # anonymous rendering rather than crash.
  attr :phoenix_kit_current_scope, :any, default: nil
  # Assigned by core's `set_routing_info` on every LV in its on_mount chain;
  # defaulted here so an exotic mount degrades instead of raising.
  attr :url_path, :string, default: nil
  attr :current_locale, :string, default: nil
  attr :page_title, :string, default: nil

  def shop_layout(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_path={@url_path || "/"}
      current_locale={@current_locale || PhoenixKitEcommerce.Translations.default_language()}
      page_title={@page_title || "Shop"}
    >
      {render_slot(@inner_block)}
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
