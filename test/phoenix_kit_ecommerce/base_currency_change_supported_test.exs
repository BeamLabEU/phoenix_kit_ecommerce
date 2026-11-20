defmodule PhoenixKitEcommerce.BaseCurrencyChangeSupportedTest do
  @moduledoc """
  A screen offering a base-currency change can learn, before its
  confirmation step, whether `reprice_for_base_change/3` would refuse. Both
  the legacy and the catalogue product source are supported; the catalogue
  source needs the shop's catalogue to be resolvable.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ShopConfig

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

  test "the legacy source supports the change" do
    assert Shop.base_currency_change_supported() == :ok
  end

  @tag :catalogue
  test "the catalogue source supports the change once the shop's catalogue resolves" do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    assert ProductSource.current() == ProductSource.Catalogue
    assert Shop.base_currency_change_supported() == {:error, :no_shop_catalogue}

    {:ok, _catalogue} = PhoenixKitEcommerce.APIFixtures.create_shop_catalogue()
    assert Shop.base_currency_change_supported() == :ok
  end
end
