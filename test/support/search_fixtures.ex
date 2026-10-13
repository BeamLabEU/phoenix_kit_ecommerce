defmodule PhoenixKitEcommerce.SearchFixtures do
  @moduledoc """
  Fixtures for the public-search tests: enabled languages, legacy products and
  categories, and (behind the optional catalogue dependency) catalogue items.

  Every write lands in the test's sandbox transaction, so nothing here needs a
  cleanup, including the `shop_product_source` switch.
  """

  # The catalogue is an optional dependency; the functions below are only
  # reached from tests tagged :catalogue.
  @compile {:no_warn_undefined,
            [PhoenixKitCatalogue.Catalogue, PhoenixKitCatalogue.Schemas.Category]}

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  @doc "Switches the Languages module on with `codes`; the first one is the default."
  def enable_languages!(codes) when is_list(codes) do
    {:ok, _} = Settings.update_boolean_setting_with_module("languages_enabled", true, "languages")

    languages =
      codes
      |> Enum.with_index()
      |> Enum.map(fn {code, index} ->
        %{"code" => code, "name" => code, "is_default" => index == 0, "is_enabled" => true}
      end)

    {:ok, _} =
      Settings.update_json_setting_with_module(
        "languages_config",
        %{"languages" => languages},
        "languages"
      )

    :ok
  end

  def disable_languages! do
    {:ok, _} =
      Settings.update_boolean_setting_with_module("languages_enabled", false, "languages")

    :ok
  end

  @doc ~s|A legacy category; `names` is the localized map, e.g. `%{"en" => "Vases"}`.|
  def legacy_category!(names, attrs \\ %{}) when is_map(names) do
    {:ok, category} = Shop.create_category(Map.merge(%{name: names}, attrs))
    category
  end

  @doc ~s|An active legacy product; `titles` is the localized map. `attrs` may carry `price: "12.50"`.|
  def legacy_product!(titles, attrs \\ %{}) when is_map(titles) do
    base = %{title: titles, price: Decimal.new("10.00"), status: "active"}
    attrs = Map.new(attrs, fn {key, value} -> {key, decimal_field(key, value)} end)
    {:ok, product} = Shop.create_product(Map.merge(base, attrs))
    product
  end

  defp decimal_field(key, value) when key in [:price, :compare_at_price] and is_binary(value),
    do: Decimal.new(value)

  defp decimal_field(_key, value), do: value

  @doc ~s|Writes the `shop_product_source` key (`"legacy"` or `"catalogue"`).|
  def set_product_source!(value) when value in ["legacy", "catalogue"] do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config |> ShopConfig.changeset(%{value: %{"value" => value}}) |> Repo.update!()
    end

    :ok
  end

  @doc "Switches the shop to the catalogue source and creates its catalogue (`decor3dprint`)."
  def catalogue_source! do
    set_product_source!("catalogue")
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    catalogue
  end

  def catalogue_category!(catalogue, name, attrs \\ %{}) do
    {:ok, category} =
      Catalogue.create_category(Map.merge(%{catalogue_uuid: catalogue.uuid, name: name}, attrs))

    category
  end

  @doc """
  Marks a catalogue category `deleted` with a direct write.

  Fixture order matters: `Catalogue.create_item/1` refuses an item in a
  category whose status is `deleted` (`category_uuid: is invalid`), and the
  catalogue's own `trash_category/1` trashes the category's items too (their
  status becomes `deleted`). So "an active item in a deleted category" can only
  exist after a stray write; this helper models exactly that. Create the items
  in the active category first, then call it.
  """
  def delete_category_directly!(category) do
    {1, _} =
      Repo.update_all(
        from(c in PhoenixKitCatalogue.Schemas.Category, where: c.uuid == ^category.uuid),
        set: [status: "deleted"]
      )

    :ok
  end

  @doc "An active, shop-active catalogue item; `attrs` override any default."
  def catalogue_item!(catalogue, name, attrs \\ %{}) do
    base = %{
      catalogue_uuid: catalogue.uuid,
      name: name,
      base_price: Decimal.new("10.00"),
      status: "active",
      data: shop_data("active")
    }

    {:ok, item} = Catalogue.create_item(Map.merge(base, attrs))
    item
  end

  @doc "The `data` map of an item or category with the given shop status."
  def shop_data(shop_status, extra \\ %{}) do
    %{"ecommerce" => Map.merge(%{"shop_status" => shop_status}, extra)}
  end
end
