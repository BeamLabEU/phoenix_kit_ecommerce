defmodule PhoenixKitEcommerce.Web.Components.CrossSells do
  @moduledoc """
  The "Add to your order" block of the cart: product cards with an "Add"
  button where the product can go straight into the cart and a "View" link
  where the shopper has to choose (options) first. Renders nothing for an
  empty list.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Web.Helpers

  attr :products, :list, required: true
  attr :currency, :any, required: true
  attr :language, :string, required: true

  def block(%{products: []} = assigns), do: ~H""

  def block(assigns) do
    ~H"""
    <section id="cart-cross-sells" class="card bg-base-100 shadow-xl mt-6">
      <div class="card-body">
        <h2 class="card-title text-xl mb-2">{gettext("Add to your order")}</h2>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div
            :for={product <- @products}
            id={"cross-sell-#{product.uuid}"}
            class="rounded-box border border-base-200 p-3 flex flex-col gap-2"
          >
            <.link navigate={Shop.product_url(product, @language)} class="block">
              <div class="h-28 bg-base-200 rounded-lg overflow-hidden flex items-center justify-center">
                <img
                  :if={Helpers.first_image(product)}
                  src={Helpers.first_image(product)}
                  alt=""
                  class="w-full h-full object-cover"
                />
                <.icon :if={!Helpers.first_image(product)} name="hero-cube" class="w-10 h-10 opacity-30" />
              </div>
              <h3 class="font-medium text-sm mt-2 line-clamp-2">
                {Translations.get_display(product, :title, @language)}
              </h3>
            </.link>
            <span class="font-bold text-primary text-sm">
              {PriceDisplay.render(product, @currency, :catalog, language: @language)}
            </span>
            <%= if quick_add?(product) do %>
              <button
                type="button"
                class="btn btn-primary btn-sm mt-auto"
                phx-click="add_cross_sell"
                phx-value-uuid={product.uuid}
                phx-disable-with={gettext("Adding...")}
              >
                {gettext("Add")}
              </button>
            <% else %>
              <.link
                navigate={Shop.product_url(product, @language)}
                class="btn btn-outline btn-sm mt-auto"
              >
                {gettext("View")}
              </.link>
            <% end %>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Whether a product can go into the cart without the shopper choosing first:
  it has no option to choose from.
  """
  @spec quick_add?(term()) :: boolean()
  def quick_add?(product), do: Shop.get_selectable_specs(product) == []
end
