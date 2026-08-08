defmodule PhoenixKitEcommerce.Vocabulary do
  @moduledoc """
  What the storefront calls the things it sells.

  A shop selling colour grading and camera crews reads badly when every heading
  says "Products", and a shop selling both needs a word that covers each. This
  module is the single place that decides, driven by the `shop_catalog_vocabulary`
  setting:

    * `"products"` — the default, and what every existing install keeps
    * `"services"` — "Services", "No services match your filters"
    * `"mixed"`    — neutral wording ("Items", "Nothing matches your filters")
                     for a shop selling both

  ## Why whole sentences and not a swappable noun

  The obvious implementation — one noun interpolated into `"No %{noun} available"` —
  produces broken Russian and Estonian. Slavic and Finnic languages inflect the
  noun for case, and the case is chosen by the surrounding sentence: "Нет
  **товаров**" and "Нет **услуг**" are both genitive plural, but the stems and
  endings differ, and other sentences in this module need nominative, partitive or
  accusative. A translator handed `"Нет %{noun}"` cannot produce correct output for
  any noun they were not shown.

  So every variant is a complete `gettext/1` literal. That is more msgids, and it
  is the only shape that lets a translator write a correct sentence. It also keeps
  extraction honest: each literal is visible to `mix gettext.extract`.

  ## This is NOT `product_type`

  `product_type` (`physical` | `digital`) is a FULFILMENT axis — it decides whether
  a line needs shipping. Vocabulary is a presentation axis. A shop selling services
  marks them `digital` so they do not ask for a delivery address, and that is
  correct and unrelated to what the catalogue heading says. Conflating the two
  would force a mixed shop to choose between shipping a physical good and calling
  it the right word.
  """

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  @setting "shop_catalog_vocabulary"
  @default "products"
  @valid ~w(products services mixed)

  @doc "The configured vocabulary; falls back to \"products\" for any unknown value."
  def current do
    case PhoenixKit.Settings.get_setting_cached(@setting, @default) do
      v when v in @valid -> v
      _ -> @default
    end
  end

  @doc "The setting key, so the settings UI and tests do not re-spell it."
  def setting_key, do: @setting

  @doc "Valid values, for building the settings selector."
  def options, do: @valid

  # --- headings -------------------------------------------------------------

  def heading do
    case current() do
      "services" -> gettext("Services")
      "mixed" -> gettext("Catalogue")
      _ -> gettext("Products")
    end
  end

  def all_items do
    case current() do
      "services" -> gettext("All Services")
      "mixed" -> gettext("Everything")
      _ -> gettext("All Products")
    end
  end

  def browse_all do
    case current() do
      "services" -> gettext("Browse All Services")
      "mixed" -> gettext("Browse Everything")
      _ -> gettext("Browse All Products")
    end
  end

  def browse_cta do
    case current() do
      "services" -> gettext("Browse Services")
      "mixed" -> gettext("Browse Catalogue")
      _ -> gettext("Browse Products")
    end
  end

  def item_column do
    case current() do
      "services" -> gettext("Service")
      "mixed" -> gettext("Item")
      _ -> gettext("Product")
    end
  end

  # --- empty and error states ----------------------------------------------

  def none_available do
    case current() do
      "services" -> gettext("No services available")
      "mixed" -> gettext("Nothing available")
      _ -> gettext("No products available")
    end
  end

  def none_match_filters do
    case current() do
      "services" -> gettext("No services match your filters")
      "mixed" -> gettext("Nothing matches your filters")
      _ -> gettext("No products match your filters")
    end
  end

  def none_in_category do
    case current() do
      "services" -> gettext("No services in this category")
      "mixed" -> gettext("Nothing in this category")
      _ -> gettext("No products in this category")
    end
  end

  def add_some_to_start do
    case current() do
      "services" -> gettext("Add some services to get started")
      "mixed" -> gettext("Add something to get started")
      _ -> gettext("Add some products to get started")
    end
  end

  def collection_blurb do
    case current() do
      "services" ->
        gettext("Browse our services across various categories")

      "mixed" ->
        gettext("Browse our catalogue across various categories")

      _ ->
        gettext("Browse our collection of products across various categories")
    end
  end

  def unavailable_now do
    case current() do
      "services" -> gettext("This service is currently unavailable")
      "mixed" -> gettext("This item is currently unavailable")
      _ -> gettext("This product is currently unavailable")
    end
  end

  def unavailable_gone do
    case current() do
      "services" -> gettext("This service is no longer available")
      "mixed" -> gettext("This item is no longer available")
      _ -> gettext("This product is no longer available")
    end
  end

  def not_found do
    case current() do
      "services" -> gettext("Service not found")
      "mixed" -> gettext("Item not found")
      _ -> gettext("Product not found")
    end
  end

  def add_failed do
    case current() do
      "services" ->
        gettext("Unable to add this service to cart. Please refresh the page and try again.")

      "mixed" ->
        gettext("Unable to add this item to cart. Please refresh the page and try again.")

      _ ->
        gettext("Unable to add this product to cart. Please refresh the page and try again.")
    end
  end
end
