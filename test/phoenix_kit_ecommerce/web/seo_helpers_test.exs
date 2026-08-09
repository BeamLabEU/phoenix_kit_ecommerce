defmodule PhoenixKitEcommerce.Web.SEOHelpersResolverStub do
  @moduledoc false
  def host("fr"), do: "shop.example.fr"
  def host("fr-FR"), do: "shop.example.fr"
  def host(_), do: nil
end

defmodule PhoenixKitEcommerce.Web.SEOHelpersTest do
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Web.SEOHelpers
  alias PhoenixKitEcommerce.Web.SEOHelpersResolverStub

  setup do
    Settings.update_setting("languages_enabled", "true")

    Settings.update_json_setting("languages_config", %{
      "languages" => [
        %{"code" => "en-US", "name" => "English", "is_default" => true, "is_enabled" => true},
        %{"code" => "fr", "name" => "French", "is_default" => false, "is_enabled" => true},
        %{"code" => "de", "name" => "German", "is_default" => false, "is_enabled" => true}
      ]
    })

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :canonical_host_resolver)
      Settings.update_setting("languages_enabled", "false")
    end)

    :ok
  end

  defp product(slug_map) do
    %Product{
      slug: slug_map,
      title: %{"en-US" => "Vase", "fr" => "Le Vase"},
      seo_title: %{},
      seo_description: %{},
      description: %{}
    }
  end

  test "hreflang only includes languages present in the RAW slug map" do
    # de has no slug — SlugResolver would silently fall back, hreflang must not
    p = product(%{"en-US" => "vase", "fr" => "le-vase"})

    codes = SEOHelpers.product_seo(p, "en-US").hreflang_links |> Enum.map(& &1.code)

    assert "en" in codes
    assert "fr" in codes
    refute "de" in codes
  end

  test "hreflang is empty for a single-language slug map" do
    p = product(%{"en-US" => "vase"})
    assert SEOHelpers.product_seo(p, "en-US").hreflang_links == []
  end

  test "resolver host lands the language on its home domain, prefix stripped" do
    Application.put_env(
      :phoenix_kit,
      :canonical_host_resolver,
      {SEOHelpersResolverStub, :host}
    )

    p = product(%{"en-US" => "vase", "fr" => "le-vase"})
    links = SEOHelpers.product_seo(p, "en-US").hreflang_links
    fr = Enum.find(links, &(&1.code == "fr"))

    assert fr.url =~ "https://shop.example.fr/"
    refute fr.url =~ "/fr/"
  end

  test "resolver-nil canonical never doubles the locale prefix" do
    p = product(%{"en-US" => "vase", "fr" => "le-vase"})
    seo = SEOHelpers.product_seo(p, "fr")

    refute seo.canonical_url =~ "/fr/fr/"
  end

  test "seo_title wins over title for page_title and og" do
    p = %{product(%{"en-US" => "vase"}) | seo_title: %{"en-US" => "Buy Vase Online"}}
    seo = SEOHelpers.product_seo(p, "en-US")

    assert seo.page_title == "Buy Vase Online"
    assert seo.og.title == "Buy Vase Online"
  end
end
