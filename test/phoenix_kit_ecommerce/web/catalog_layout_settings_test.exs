defmodule PhoenixKitEcommerce.Web.CatalogLayoutSettingsTest do
  @moduledoc """
  The catalog's layout settings, on `/shop` and a category page:

    * `shop_sidebar_enabled` - off drops the desktop `<aside>`, gives the
      products the full width (a wider grid), and keeps the filters and the
      categories reachable at every width;
    * `shop_category_display` - `buttons` shows one wrapping row of buttons
      ("All" first, the current category highlighted) instead of the category
      cards and the mobile category list.

  The defaults must leave the page exactly as it was.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop

  # Each page keeps its own token order, so the default markup is unchanged.
  @shop_grid "grid gap-6 grid-cols-1 sm:grid-cols-2 xl:grid-cols-3"
  @shop_wide_grid "grid gap-6 grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"
  @category_grid "grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-6"
  @category_wide_grid "grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6"

  @aside "aside"
  @with_sidebar ~s(div[class~="lg:grid-cols-4"][class~="gap-8"])
  @narrow_column ~s(div[class~="lg:col-span-3"])
  @phone_only ~s(div[class~="lg:hidden"])
  @filters_button "button[phx-click='toggle_mobile_filters']"
  @chips "#category-chips"
  # Product cards are links too; the category cards are the ones with a 7rem picture.
  @category_cards "a.card figure.h-28"

  setup do
    # The settings cache is ETS-backed and is not rolled back by the sandbox.
    on_exit(fn ->
      Settings.update_setting("shop_sidebar_enabled", "true")
      Settings.update_setting("shop_category_display", "cards")
      Settings.update_setting("shop_sidebar_show_categories", "true")
    end)

    alpha = create_category("Alpha Prints")
    beta = create_category("Beta Prints")
    create_product("Alpha Vase", alpha)
    create_product("Beta Vase", beta)

    {:ok, alpha: alpha, beta: beta}
  end

  describe "defaults" do
    test "the shop page keeps its sidebar, its cards and its phone-only helpers", %{conn: conn} do
      {:ok, view, html} = live(conn, "/shop")

      assert has_element?(view, @aside)
      assert has_element?(view, @with_sidebar)
      assert has_element?(view, @narrow_column)
      assert html =~ ~s(class="#{@shop_grid}")
      assert has_element?(view, @category_cards)
      assert has_element?(view, "#{@phone_only} details")
      assert has_element?(view, "#{@phone_only} #{@filters_button}")
      refute has_element?(view, @chips)
    end

    test "the category page keeps its sidebar and phone-only helpers", %{conn: conn, alpha: alpha} do
      {:ok, view, html} = live(conn, Shop.category_url(alpha, "en"))

      assert has_element?(view, @aside)
      assert has_element?(view, @with_sidebar)
      assert has_element?(view, @narrow_column)
      assert html =~ ~s(class="#{@category_grid}")
      assert has_element?(view, "#{@phone_only} details")
      assert has_element?(view, "#{@phone_only} #{@filters_button}")
      refute has_element?(view, @chips)
    end
  end

  describe "sidebar off" do
    setup do
      Settings.update_setting("shop_sidebar_enabled", "false")
      :ok
    end

    test "the shop page drops the aside and spans the full width", %{conn: conn} do
      {:ok, view, html} = live(conn, "/shop")

      refute has_element?(view, @aside)
      refute has_element?(view, @with_sidebar)
      refute has_element?(view, @narrow_column)
      assert html =~ ~s(class="#{@shop_wide_grid}")
    end

    test "the filters button and the category list stay at every width", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/shop")

      assert has_element?(view, @filters_button)
      refute has_element?(view, "#{@phone_only} #{@filters_button}")
      assert has_element?(view, "details")
      refute has_element?(view, "#{@phone_only} details")
    end

    test "the filters drawer opens at every width", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/shop")

      view |> element(@filters_button) |> render_click()

      assert has_element?(view, ~s(form[phx-submit="filter_search"]))
      refute has_element?(view, "#{@phone_only} form[phx-submit='filter_search']")
    end

    test "the category page drops the aside too", %{conn: conn, alpha: alpha} do
      {:ok, view, html} = live(conn, Shop.category_url(alpha, "en"))

      refute has_element?(view, @aside)
      refute has_element?(view, @narrow_column)
      assert html =~ ~s(class="#{@category_wide_grid}")
      assert has_element?(view, @filters_button)
      refute has_element?(view, "#{@phone_only} #{@filters_button}")
      assert has_element?(view, "details")
      refute has_element?(view, "#{@phone_only} details")
    end
  end

  describe "category buttons" do
    setup do
      Settings.update_setting("shop_category_display", "buttons")
      :ok
    end

    test "the shop page shows one row: All first, then every category", %{
      conn: conn,
      alpha: alpha,
      beta: beta
    } do
      {:ok, view, _html} = live(conn, "/shop")

      assert chip_labels(view) == ["All Products", "Alpha Prints", "Beta Prints"]

      assert chip_hrefs(view) == [
               Shop.catalog_url("en"),
               Shop.category_url(alpha, "en"),
               Shop.category_url(beta, "en")
             ]

      # Replaces the cards and the phone category list, so nothing is doubled.
      refute has_element?(view, @category_cards)
      refute has_element?(view, "#{@phone_only} details")
      assert has_element?(view, @aside)
    end

    test "on the shop page All is the highlighted one", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/shop")

      assert active_chip_labels(view) == ["All Products"]
    end

    test "the links carry no locale on a single-language site", %{conn: conn} do
      Settings.update_setting("languages_enabled", "false")

      {:ok, view, _html} = live(conn, "/shop")

      for href <- chip_hrefs(view), do: refute(href =~ ~r{^/(en|uk|de|ru|et|fr)(/|$)})
    end

    test "the links keep the active filters", %{conn: conn, alpha: alpha} do
      {:ok, view, _html} = live(conn, "/shop?search=vase")

      assert chip_hrefs(view) |> Enum.all?(&String.ends_with?(&1, "?search=vase"))
      assert (Shop.category_url(alpha, "en") <> "?search=vase") in chip_hrefs(view)
    end

    test "the links keep the active filters on a category page without a sidebar", %{
      conn: conn,
      alpha: alpha,
      beta: beta
    } do
      Settings.update_setting("shop_sidebar_enabled", "false")

      {:ok, view, _html} = live(conn, Shop.category_url(alpha, "en") <> "?search=vase")

      assert active_chip_labels(view) == ["Alpha Prints"]
      assert (Shop.category_url(beta, "en") <> "?search=vase") in chip_hrefs(view)
      assert (Shop.catalog_url("en") <> "?search=vase") in chip_hrefs(view)
    end

    test "the highlighted button is marked as the current page", %{conn: conn, alpha: alpha} do
      {:ok, view, _html} = live(conn, Shop.category_url(alpha, "en"))

      assert has_element?(view, "#{@chips} a.btn-primary[aria-current='page']", "Alpha Prints")
      assert has_element?(view, "#{@chips} a.btn-outline:not([aria-current])", "Beta Prints")
    end

    test "with categories switched off in the shop the shop page shows no row", %{conn: conn} do
      Settings.update_setting("shop_sidebar_show_categories", "false")

      {:ok, view, _html} = live(conn, "/shop")

      refute has_element?(view, @chips)
      # The categories stay reachable on a phone, as they always were.
      assert has_element?(view, "#{@phone_only} details")
    end

    test "the category page highlights the current category, always", %{conn: conn, alpha: alpha} do
      Settings.update_setting("shop_sidebar_show_categories", "false")

      {:ok, view, _html} = live(conn, Shop.category_url(alpha, "en"))

      assert chip_labels(view) == ["All Products", "Alpha Prints", "Beta Prints"]
      assert active_chip_labels(view) == ["Alpha Prints"]
      refute has_element?(view, "#{@phone_only} details")
    end

    test "the row also serves a shop without a sidebar", %{conn: conn} do
      Settings.update_setting("shop_sidebar_enabled", "false")

      {:ok, view, _html} = live(conn, "/shop")

      assert chip_labels(view) == ["All Products", "Alpha Prints", "Beta Prints"]
      refute has_element?(view, @aside)
      refute has_element?(view, "details")
    end
  end

  describe "category buttons on a multi-language site" do
    setup do
      Settings.update_setting("shop_category_display", "buttons")
      Settings.update_setting("languages_enabled", "true")

      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{"code" => "en", "name" => "en", "is_enabled" => true, "is_default" => true},
          %{"code" => "uk", "name" => "uk", "is_enabled" => true, "is_default" => false}
        ]
      })

      Languages.set_default_language_no_prefix(false)

      on_exit(fn ->
        Settings.update_setting("languages_enabled", "false")
        Settings.update_json_setting("languages_config", %{"languages" => []})
        Languages.set_default_language_no_prefix(false)
      end)

      :ok
    end

    test "carry the page's locale", %{conn: conn, alpha: alpha} do
      {:ok, view, _html} = live(conn, "/uk/shop")

      hrefs = chip_hrefs(view)

      assert Shop.catalog_url("uk") in hrefs
      assert Shop.category_url(alpha, "uk") in hrefs
      assert Enum.all?(hrefs, &String.starts_with?(&1, "/uk/"))
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp chips(view) do
    view |> render() |> LazyHTML.from_document() |> LazyHTML.query("#category-chips a")
  end

  defp chip_labels(view),
    do: view |> chips() |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp chip_hrefs(view),
    do: view |> chips() |> Enum.map(&(&1 |> LazyHTML.attribute("href") |> List.first()))

  defp active_chip_labels(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#category-chips a.btn-primary")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp create_category(name) do
    {:ok, category} = Shop.create_category(%{"name" => %{"en" => name}, "status" => "active"})
    category
  end

  defp create_product(title, category) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => title},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "category_uuid" => category.uuid
      })

    product
  end
end
