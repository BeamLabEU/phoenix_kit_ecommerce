defmodule PhoenixKitEcommerce.Catalogue.ShopSections do
  @moduledoc """
  Function components rendering the "Shop" section that
  `PhoenixKitEcommerce.Catalogue.Extension` adds to the catalogue item and
  category forms. Field names/labels are ported from
  `PhoenixKitEcommerce.Web.ProductForm`'s Pricing card and
  `PhoenixKitEcommerce.Web.CategoryForm`'s basic-fields card, adapted to the
  `item[ecommerce][...]` / `category[ecommerce][...]` namespace the
  extension slot absorbs (see `PhoenixKitCatalogue.Extensions.absorb/3`).

  Fields only the Shopify sync or a data migration ever write
  (`shopify`, `price_modifiers`, `legacy_product_uuid`,
  `translation_fingerprints`, `storefront_filters`) have no form input here.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select

  @doc """
  Shop section for the item form. `assigns` carries `:form`, `:item`,
  `:data` (the item's `data`, so `data["ecommerce"]` is the current
  commerce map) and `:current_language`.
  """
  def item(assigns) do
    ecommerce = Map.get(assigns[:data] || %{}, "ecommerce", %{})
    current_language = assigns[:current_language] || "en"
    price_unit = Map.get(ecommerce, "price_unit", %{})
    other_price_units = Enum.reject(price_unit, fn {lang, _} -> lang == current_language end)

    assigns =
      assigns
      |> assign(:ecommerce, ecommerce)
      |> assign(:current_language, current_language)
      |> assign(:price_unit, price_unit)
      |> assign(:other_price_units, other_price_units)

    ~H"""
    <div id="ext-ecommerce-section" class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-xl mb-4">{gettext("Shop")}</h2>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-x-4 gap-y-4">
          <div class="fieldset w-full">
            <.select
              name="item[ecommerce][shop_status]"
              value={Map.get(@ecommerce, "shop_status", "draft")}
              label={gettext("Shop status")}
              options={[
                {gettext("Draft"), "draft"},
                {gettext("Active"), "active"},
                {gettext("Archived"), "archived"}
              ]}
            />
          </div>

          <div class="fieldset w-full">
            <.select
              name="item[ecommerce][product_type]"
              value={Map.get(@ecommerce, "product_type", "physical")}
              label={gettext("Product Type")}
              options={[{gettext("Physical"), "physical"}, {gettext("Digital"), "digital"}]}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][vendor]"
              value={Map.get(@ecommerce, "vendor")}
              type="text"
              label={gettext("Vendor")}
              placeholder={gettext("Brand or manufacturer")}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][tags]"
              value={Enum.join(Map.get(@ecommerce, "tags", []), ", ")}
              type="text"
              label={gettext("Tags")}
              placeholder={gettext("comma, separated, tags")}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][compare_at_price]"
              value={Map.get(@ecommerce, "compare_at_price")}
              type="number"
              step="0.01"
              min="0"
              label={gettext("Compare at Price")}
              placeholder={gettext("Original price")}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][cost_per_item]"
              value={Map.get(@ecommerce, "cost_per_item")}
              type="number"
              step="0.01"
              min="0"
              label={gettext("Cost per Item")}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][currency]"
              value={Map.get(@ecommerce, "currency", "USD")}
              type="text"
              maxlength="3"
              label={gettext("Currency")}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][weight_grams]"
              value={Map.get(@ecommerce, "weight_grams", 0)}
              type="number"
              min="0"
              label={gettext("Weight (grams)")}
            />
          </div>

          <div class="fieldset w-full">
            <.checkbox
              name="item[ecommerce][taxable]"
              checked={Map.get(@ecommerce, "taxable", true)}
              label={gettext("Charge tax on this item")}
            />
          </div>

          <div class="fieldset w-full">
            <.checkbox
              name="item[ecommerce][requires_shipping]"
              checked={Map.get(@ecommerce, "requires_shipping", true)}
              label={gettext("Requires shipping")}
            />
          </div>

          <div class="fieldset w-full">
            <.checkbox
              name="item[ecommerce][made_to_order]"
              checked={Map.get(@ecommerce, "made_to_order", false)}
              label={gettext("Made to order (always available)")}
            />
          </div>

          <div class="fieldset w-full">
            <.checkbox
              name="item[ecommerce][price_from]"
              checked={Map.get(@ecommerce, "price_from", false)}
              label={gettext("Show \"From\" before the price")}
            />
          </div>

          <div class="fieldset w-full">
            <.checkbox
              name="item[ecommerce][price_on_request]"
              checked={Map.get(@ecommerce, "price_on_request", false)}
              label={gettext("Price on request (hide the amount)")}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name={"item[ecommerce][price_unit][#{@current_language}]"}
              value={Map.get(@price_unit, @current_language, "")}
              type="text"
              maxlength="32"
              label={gettext("Price unit")}
              placeholder={gettext("e.g. per hour, per m2, per litre")}
            />
            <%!-- Other languages' units must survive a save made while a
                 different tab is active. --%>
            <input
              :for={{lang, text} <- @other_price_units}
              type="hidden"
              name={"item[ecommerce][price_unit][#{lang}]"}
              value={text}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][file_uuid]"
              value={Map.get(@ecommerce, "file_uuid")}
              type="text"
              label={gettext("Digital file (Storage uuid)")}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][download_limit]"
              value={Map.get(@ecommerce, "download_limit")}
              type="number"
              min="1"
              label={gettext("Download limit")}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][download_expiry_days]"
              value={Map.get(@ecommerce, "download_expiry_days")}
              type="number"
              min="1"
              label={gettext("Download expiry (days)")}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Shop section for the category form. `assigns` carries `:form`,
  `:category`, `:data` (the category's `data`) and `:current_language`.
  """
  def category(assigns) do
    ecommerce = Map.get(assigns[:data] || %{}, "ecommerce", %{})
    assigns = assign(assigns, :ecommerce, ecommerce)

    ~H"""
    <div id="ext-ecommerce-section" class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-xl mb-4">{gettext("Shop")}</h2>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-x-4 gap-y-4">
          <div class="fieldset w-full">
            <.select
              name="category[ecommerce][shop_status]"
              value={Map.get(@ecommerce, "shop_status", "active")}
              label={gettext("Shop status")}
              options={[
                {gettext("Active — Category and items visible"), "active"},
                {gettext("Unlisted — Category hidden, items still visible"), "unlisted"},
                {gettext("Hidden — Category and items hidden"), "hidden"}
              ]}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="category[ecommerce][image_uuid]"
              value={Map.get(@ecommerce, "image_uuid")}
              type="text"
              label={gettext("Category image (Storage uuid)")}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="category[ecommerce][featured_item_uuid]"
              value={Map.get(@ecommerce, "featured_item_uuid")}
              type="text"
              label={gettext("Featured item (image fallback)")}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end
end
