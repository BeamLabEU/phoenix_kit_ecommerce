defmodule PhoenixKitEcommerce.Web.Components.RelatedProducts do
  @moduledoc """
  The "You may also like" block under a product: a row of product cards.
  Renders nothing for an empty list, so a product without related products
  (and a shop that never sets any) keeps its page exactly as it was.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  alias PhoenixKitEcommerce.NamePrefix
  alias PhoenixKitEcommerce.Web.Components.ShopCards

  attr :products, :list, required: true
  attr :currency, :any, required: true
  attr :language, :string, required: true

  def block(%{products: []} = assigns), do: ~H""

  def block(assigns) do
    # Read once for the whole row, not once per card (as the catalog grids do).
    assigns = assign(assigns, :name_prefixes, NamePrefix.prefixes())

    ~H"""
    <section id="related-products" class="mt-10">
      <div class="divider"></div>
      <h2 class="text-xl font-semibold mb-4">{gettext("You may also like")}</h2>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <ShopCards.product_card
          :for={product <- @products}
          product={product}
          currency={@currency}
          language={@language}
          name_prefixes={@name_prefixes}
        />
      </div>
    </section>
    """
  end
end
