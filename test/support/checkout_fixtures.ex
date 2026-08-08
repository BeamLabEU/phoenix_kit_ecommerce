defmodule PhoenixKitEcommerce.CheckoutFixtures do
  @moduledoc """
  Shared billing-data builders for checkout-flow tests.

  `complete_billing/2` is the minimal, always-valid billing map used
  both for `Shop.convert_cart_to_order/2`'s `:billing_data` option
  (context-level tests) and as the source of truth for the checkout
  page's billing form payload (LiveView tests) — one shape, two
  callers, so a required billing field never drifts between them.

  Imported into `PhoenixKitEcommerce.DataCase` and
  `PhoenixKitEcommerce.LiveCase` so every checkout test can reach it.
  """

  import Phoenix.LiveViewTest, only: [form: 3]

  @doc """
  A minimal, always-valid billing map for `country`.

  `email_prefix` only distinguishes the generated email in test/failure
  output (handy for telling fixtures from different test files apart)
  — it carries no test semantics and defaults to `"checkout-fixture"`.
  """
  def complete_billing(country, email_prefix \\ "checkout-fixture") do
    %{
      "email" => "#{email_prefix}-#{System.unique_integer([:positive])}@example.com",
      "first_name" => "Test",
      "last_name" => "Buyer",
      "address_line1" => "1 Test Street",
      "city" => "Testville",
      "postal_code" => "10001",
      "country" => country
    }
  end

  @doc """
  Builds the checkout page's `#checkout-billing-form` change/submit
  payload for `country`, built on top of `complete_billing/2` so the
  form and the direct-conversion path never disagree on required
  billing fields.
  """
  def fill_billing_form(view, country: country) do
    billing = complete_billing(country, "checkout-shipping")

    form(view, "#checkout-billing-form", billing: billing)
  end
end
