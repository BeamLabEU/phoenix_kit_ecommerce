defmodule PhoenixKitEcommerce.Web.ShopifySyncTabsTest do
  @moduledoc """
  The Shopify Sync page splits into three tabs — "Check for changes",
  "Media & collections" and "Settings" — instead of stacking every panel
  down one column. The page had grown to four unrelated panels plus the
  diff report, and the operator had to scroll past the sync-scope form and
  the media buttons to reach the changes they came for.

  Each tab owns its panels exclusively: the check button and the diff
  report belong to the first, the three media writers to the second, the
  sync-scope form and the jump to the integration's own settings to the
  third.

  Needs `phoenix_kit_catalogue` loaded — the media and settings panels are
  gated on `ProductSource.current/0 == Catalogue`, which is unconditionally
  `Legacy` without that optional dependency — so tagged `:catalogue` and
  excluded via `test_helper.exs`, same as the rest of the page's suite.
  `async: false`: flips the process-wide `shop_product_source` key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  setup %{conn: conn} do
    on_exit(fn -> set_product_source("legacy") end)
    set_product_source("catalogue")

    uuid = connect_shopify()

    {:ok, conn: put_test_scope(conn, fake_scope()), integration_uuid: uuid}
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  defp connect_shopify do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("shopify", "Test Shop #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "shop_domain" => "test-shop.myshopify.com",
        "access_token" => "shpat_test_token"
      })

    uuid
  end

  describe "tab strip" do
    test "renders all three tabs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      assert has_element?(view, ~s(#sync-tabs [phx-value-tab="check"]))
      assert has_element?(view, ~s(#sync-tabs [phx-value-tab="media"]))
      assert has_element?(view, ~s(#sync-tabs [phx-value-tab="settings"]))
    end

    test "opens on the check tab: its button is there, the other panels are not",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      assert has_element?(view, "#check-shopify-changes")
      refute has_element?(view, "#media-sync-panel")
      refute has_element?(view, "#sync-scope-panel")
    end
  end

  describe "switching" do
    test "the media tab shows the three writers and hides the check button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      view |> element(~s(#sync-tabs [phx-value-tab="media"])) |> render_click()

      assert has_element?(view, "#media-sync-panel")

      for kind <- ~w(images variants collections) do
        assert has_element?(view, "#sync-media-#{kind}")
      end

      refute has_element?(view, "#check-shopify-changes")
      refute has_element?(view, "#sync-scope-panel")
    end

    test "the settings tab shows the sync-scope form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      view |> element(~s(#sync-tabs [phx-value-tab="settings"])) |> render_click()

      assert has_element?(view, "#sync-scope-panel")
      assert has_element?(view, "#sync-scope-form")
      refute has_element?(view, "#media-sync-panel")
      refute has_element?(view, "#check-shopify-changes")
    end

    test "an unknown tab id leaves the current tab alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      render_click(view, "switch_tab", %{"tab" => "nope"})

      assert has_element?(view, "#check-shopify-changes")
    end
  end

  describe "settings tab — jump to the integration" do
    test "links straight at the connected integration's own settings",
         %{conn: conn, integration_uuid: uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      view |> element(~s(#sync-tabs [phx-value-tab="settings"])) |> render_click()

      assert has_element?(
               view,
               ~s(#open-shopify-integration[href$="/admin/settings/integrations/#{uuid}"])
             )
    end
  end

  describe "legacy source" do
    test "offers only the check tab — the other two have no panels to show",
         %{conn: conn} do
      set_product_source("legacy")

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      assert has_element?(view, "#check-shopify-changes")
      refute has_element?(view, ~s(#sync-tabs [phx-value-tab="media"]))
      refute has_element?(view, ~s(#sync-tabs [phx-value-tab="settings"]))
    end
  end
end
