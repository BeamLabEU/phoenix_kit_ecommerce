defmodule PhoenixKitEcommerce.BillingSupport do
  @moduledoc """
  What the installed `phoenix_kit_billing` can do for the checkout form.

  A billing release after 0.24 adds the `require_phone` option to
  `BillingProfile.fields_changeset/3` and an attribute of the same name to
  `BillingProfileFields.billing_profile_fields/1`. This package's billing
  requirement is lower than that, so the checkout asks the installed billing
  rather than assuming: with the option, billing validates the phone and marks
  the input; without it, the checkout validates the phone itself and the input
  is left unmarked.

  The attribute is passed to the component as a dynamic attribute list
  (`phone_attrs/0`), never written in the template: a literal
  `require_phone` against a billing that does not declare it is a compile-time
  warning, and this package compiles with warnings as errors.

  The `:billing_require_phone_support` application env (`true` or `false`)
  overrides the probe; tests use it to run both shapes against one billing.
  """

  alias PhoenixKitBilling.Web.Components.BillingProfileFields

  @doc "Whether the installed billing knows the `require_phone` option."
  @spec supported?() :: boolean()
  def supported? do
    case Application.get_env(:phoenix_kit_ecommerce, :billing_require_phone_support) do
      override when is_boolean(override) -> override
      _ -> component_declares_require_phone?()
    end
  end

  @doc """
  Dynamic attributes for the billing fields component: `require_phone: true`
  when the shop requires a phone and billing can mark the input, else none.
  """
  @spec phone_attrs() :: [require_phone: true] | []
  def phone_attrs do
    if PhoenixKitEcommerce.require_phone_at_checkout?() and supported?(),
      do: [require_phone: true],
      else: []
  end

  @doc """
  Requires the phone on the changeset when the shop asks for it and billing
  did not already do so through `fields_changeset/3`.
  """
  @spec require_phone(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def require_phone(changeset) do
    if PhoenixKitEcommerce.require_phone_at_checkout?() and not supported?(),
      do: Ecto.Changeset.validate_required(changeset, [:phone]),
      else: changeset
  end

  defp component_declares_require_phone? do
    Code.ensure_loaded?(BillingProfileFields) and
      function_exported?(BillingProfileFields, :__components__, 0) and
      BillingProfileFields.__components__()
      |> Map.get(:billing_profile_fields, %{})
      |> Map.get(:attrs, [])
      |> Enum.any?(&(&1.name == :require_phone))
  rescue
    _ -> false
  end
end
