defmodule PhoenixKitEcommerce.BillingSupport do
  @moduledoc """
  What the installed `phoenix_kit_billing` can do for the checkout form.

  A billing release after 0.24 adds the `require_phone` option to
  `BillingProfile.fields_changeset/3` and an attribute of the same name to
  `BillingProfileFields.billing_profile_fields/1`. This package's billing
  requirement is lower than that, so the checkout asks the installed billing
  whether the component declares the attribute, and passes it only then. The
  phone check itself never depends on this: the checkout and the order
  conversion require the phone on their own whenever the setting is on, so a
  wrong answer here can only cost the input its required mark.

  The attribute is passed to the component as a dynamic attribute list
  (`phone_attrs/1`), never written in the template: a literal `require_phone`
  against a billing that does not declare it is a compile-time warning, and
  this package compiles with warnings as errors.

  The `:billing_require_phone_support` application env (`true` or `false`)
  overrides the probe; tests use it to run both shapes against one billing.

  Remove this module (and the `{@phone_attrs}` pass-through in the checkout)
  when the minimum billing requirement reaches the release that has
  `require_phone`.
  """

  alias PhoenixKitBilling.Web.Components.BillingProfileFields

  @doc "Whether the installed billing's fields component declares `require_phone`."
  @spec supported?() :: boolean()
  def supported? do
    case Application.get_env(:phoenix_kit_ecommerce, :billing_require_phone_support) do
      override when is_boolean(override) -> override
      _ -> declares_require_phone?(BillingProfileFields)
    end
  end

  @doc """
  Whether `component_module`'s `billing_profile_fields/1` declares a
  `require_phone` attribute.
  """
  @spec declares_require_phone?(module()) :: boolean()
  def declares_require_phone?(component_module) do
    component_module.__components__()
    |> Map.get(:billing_profile_fields, %{})
    |> Map.get(:attrs, [])
    |> Enum.any?(&(&1.name == :require_phone))
  end

  @doc """
  Dynamic attributes for the billing fields component: `require_phone: true`
  when the shop requires a phone (`required?`) and billing can mark the input,
  else none.
  """
  @spec phone_attrs(boolean()) :: [require_phone: true] | []
  def phone_attrs(required?) do
    if required? and supported?(), do: [require_phone: true], else: []
  end
end
