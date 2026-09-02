defmodule PhoenixKitEcommerce.I18nTest do
  @moduledoc """
  Smoke test for the per-module i18n wiring.

  Confirms that:
    * Every tab registered by `PhoenixKitEcommerce.admin_tabs/0`,
      `settings_tabs/0`, and `user_dashboard_tabs/0` carries
      `gettext_backend: PhoenixKitEcommerce.Gettext`.
    * The shipped `priv/gettext/<locale>/LC_MESSAGES/default.po`
      catalogues resolve through the backend directly and through
      `Tab.localized_label/1`.
    * Falls back to the raw msgid for an unknown locale.
  """

  use ExUnit.Case, async: false

  # Excluded by `test/test_helper.exs` when running against a `phoenix_kit`
  # release that pre-dates the `gettext_backend` API (PR BeamLabEU/phoenix_kit#522).
  # Once the consumer's `phoenix_kit` dep resolves to a release that ships
  # `Tab.localized_label/1`, the helper detects it and these tests run
  # automatically — no follow-up edit needed.
  @moduletag :requires_phoenix_kit_i18n_api

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKitEcommerce.Gettext, as: EcommerceGettext

  setup do
    original = Gettext.get_locale(EcommerceGettext)
    on_exit(fn -> Gettext.put_locale(EcommerceGettext, original) end)
    :ok
  end

  describe "tab wiring" do
    test "every registered tab carries the module's own gettext backend" do
      tabs =
        PhoenixKitEcommerce.admin_tabs() ++
          PhoenixKitEcommerce.settings_tabs() ++
          PhoenixKitEcommerce.user_dashboard_tabs()

      # Sanity: 8 admin + 1 settings + 2 user-dashboard = 11 sites.
      assert length(tabs) == 11

      for tab <- tabs do
        assert tab.gettext_backend == EcommerceGettext,
               "Tab #{inspect(tab.id)} is missing or wrong gettext_backend " <>
                 "(got #{inspect(tab.gettext_backend)})"

        assert tab.gettext_domain == "default"
      end
    end
  end

  describe "backend catalogue lookup" do
    test "ru locale resolves 'E-Commerce' through the backend directly" do
      Gettext.put_locale(EcommerceGettext, "ru")
      assert Gettext.gettext(EcommerceGettext, "E-Commerce") == "Электронная коммерция"
    end

    test "et locale resolves 'My Cart' through the backend directly" do
      Gettext.put_locale(EcommerceGettext, "et")
      assert Gettext.gettext(EcommerceGettext, "My Cart") == "Minu ostukorv"
    end
  end

  describe "Tab.localized_label/1 against the module's catalogue" do
    test "ru locale resolves the parent 'E-Commerce' tab to 'Электронная коммерция'" do
      Gettext.put_locale(EcommerceGettext, "ru")

      parent = admin_shop_tab()
      assert Tab.localized_label(parent) == "Электронная коммерция"
    end

    test "et locale resolves the parent 'E-Commerce' tab to 'E-kaubandus'" do
      Gettext.put_locale(EcommerceGettext, "et")

      parent = admin_shop_tab()
      assert Tab.localized_label(parent) == "E-kaubandus"
    end

    test "unknown locale falls back to the raw msgid" do
      Gettext.put_locale(EcommerceGettext, "zz")

      parent = admin_shop_tab()
      assert Tab.localized_label(parent) == parent.label
    end
  end

  describe "plural catalogue coverage (de, fr)" do
    # German's plural rule sends n=0 to the *plural* index (msgstr[1]), so a
    # hardcoded "1 ..." in msgstr[0] is only ever reached at n=1 and a bug
    # there is harmless. French sends n=0 to the *singular* index
    # (msgstr[0]) instead — a hardcoded "1 ..." there is reached at n=0 and
    # renders "1 item" for an empty cart. These assertions cover n=0
    # specifically because that is the case a plain smoke test at n=1 (or a
    # substring check against the msgid) cannot distinguish from correct.
    test "de resolves plural forms at n=0, 1, 2" do
      Gettext.put_locale(EcommerceGettext, "de")

      for {msgid, msgid_plural, expected} <- de_plural_fixtures(),
          {n, want} <- expected do
        got = Gettext.dngettext(EcommerceGettext, "default", msgid, msgid_plural, n, count: n)

        assert got == want,
               "de n=#{n} #{inspect(msgid)}: got #{inspect(got)}, want #{inspect(want)}"
      end
    end

    test "fr resolves plural forms at n=0, 1, 2" do
      Gettext.put_locale(EcommerceGettext, "fr")

      for {msgid, msgid_plural, expected} <- fr_plural_fixtures(),
          {n, want} <- expected do
        got = Gettext.dngettext(EcommerceGettext, "default", msgid, msgid_plural, n, count: n)

        assert got == want,
               "fr n=#{n} #{inspect(msgid)}: got #{inspect(got)}, want #{inspect(want)}"
      end
    end
  end

  defp admin_shop_tab do
    Enum.find(PhoenixKitEcommerce.admin_tabs(), &(&1.id == :admin_shop))
  end

  defp de_plural_fixtures do
    [
      {"1 category", "%{count} categories",
       %{0 => "0 Kategorien", 1 => "1 Kategorie", 2 => "2 Kategorien"}},
      {"1 product", "%{count} products",
       %{0 => "0 Produkte", 1 => "1 Produkt", 2 => "2 Produkte"}},
      {"1 item", "%{count} items", %{0 => "0 Artikel", 1 => "1 Artikel", 2 => "2 Artikel"}},
      {"1 cart total", "%{count} carts total",
       %{
         0 => "0 Warenkörbe insgesamt",
         1 => "1 Warenkorb insgesamt",
         2 => "2 Warenkörbe insgesamt"
       }},
      {"1 method configured", "%{count} methods configured",
       %{
         0 => "0 Methoden konfiguriert",
         1 => "1 Methode konfiguriert",
         2 => "2 Methoden konfiguriert"
       }},
      {"1 day", "%{count} days", %{0 => "0 Tage", 1 => "1 Tag", 2 => "2 Tage"}}
    ]
  end

  defp fr_plural_fixtures do
    [
      {"1 category", "%{count} categories",
       %{0 => "0 catégorie", 1 => "1 catégorie", 2 => "2 catégories"}},
      {"1 product", "%{count} products",
       %{0 => "0 produit", 1 => "1 produit", 2 => "2 produits"}},
      {"1 item", "%{count} items", %{0 => "0 article", 1 => "1 article", 2 => "2 articles"}},
      {"1 cart total", "%{count} carts total",
       %{0 => "0 panier au total", 1 => "1 panier au total", 2 => "2 paniers au total"}},
      {"1 method configured", "%{count} methods configured",
       %{
         0 => "0 méthode configurée",
         1 => "1 méthode configurée",
         2 => "2 méthodes configurées"
       }},
      {"1 day", "%{count} days", %{0 => "0 jour", 1 => "1 jour", 2 => "2 jours"}}
    ]
  end
end
