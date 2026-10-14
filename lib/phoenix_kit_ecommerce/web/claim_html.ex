defmodule PhoenixKitEcommerce.Web.ClaimHTML do
  @moduledoc """
  The checkout claim page: a bare card inside the host's root
  layout, in the language of the claim. One form posts back to the claim URL
  with the CSRF token; `offer` tells the server what the page showed (`none`,
  or the uuid of the buyer's own cart) so a change in between is noticed.
  """

  use PhoenixKitEcommerce.Web, :html

  alias PhoenixKitEcommerce.Web.Helpers

  attr :cart, :map, required: true
  attr :existing, :map, default: nil
  attr :action, :string, required: true

  def interstitial(assigns) do
    ~H"""
    <div id="claim-page" class="min-h-screen flex items-center justify-center bg-base-200 p-4">
      <div class="card bg-base-100 shadow-xl w-full max-w-lg">
        <div class="card-body gap-4">
          <h1 class="card-title text-xl">{gettext("An assistant prepared this cart for you")}</h1>

          <ul id="claim-lines" class="divide-y divide-base-200">
            <li
              :for={item <- @cart.items}
              id={"claim-line-#{item.uuid}"}
              class="flex justify-between gap-4 py-2 text-sm"
            >
              <span>
                {item.product_title}
                <span class="text-base-content/60">×{item.quantity}</span>
              </span>
              <span class="font-medium">{Helpers.format_price(item.line_total, @cart.currency)}</span>
            </li>
          </ul>

          <div class="flex justify-between font-semibold">
            <span>{gettext("Subtotal")}</span>
            <span id="claim-subtotal">{Helpers.format_price(@cart.subtotal, @cart.currency)}</span>
          </div>

          <form :if={is_nil(@existing)} id="claim-form" method="post" action={@action} class="flex flex-col gap-2">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <input type="hidden" name="offer" value="none" />
            <button
              type="submit"
              id="claim-continue"
              class="btn btn-primary btn-block transition-transform hover:scale-[1.01]"
            >
              {gettext("Continue to checkout")}
            </button>
          </form>

          <form :if={@existing} id="claim-form" method="post" action={@action} class="flex flex-col gap-3">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <input type="hidden" name="offer" value={@existing.uuid} />
            <p class="text-sm text-base-content/70">
              {gettext("You already have items in your cart. What would you like to do?")}
            </p>
            <button
              type="submit"
              name="choice"
              value="add"
              id="claim-add"
              class="btn btn-primary btn-block transition-transform hover:scale-[1.01]"
            >
              {gettext("Add these items to my cart")}
            </button>
            <button
              type="submit"
              name="choice"
              value="replace"
              id="claim-replace"
              class="btn btn-outline btn-block transition-transform hover:scale-[1.01]"
            >
              {gettext("Replace my cart")}
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
