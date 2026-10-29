defmodule PhoenixKitEcommerce.BillingSupportTest do
  use ExUnit.Case, async: false

  alias PhoenixKitBilling.BillingProfile
  alias PhoenixKitEcommerce.BillingSupport

  defmodule WithPhone do
    use Phoenix.Component

    attr(:form, :any, required: true)
    attr(:require_phone, :boolean, default: false)

    def billing_profile_fields(assigns), do: ~H""
  end

  defmodule WithoutPhone do
    use Phoenix.Component

    attr(:form, :any, required: true)
    attr(:require_email, :boolean, default: false)

    def billing_profile_fields(assigns), do: ~H""
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ecommerce, :billing_require_phone_support)
    end)
  end

  describe "declares_require_phone?/1" do
    test "is true for a component that declares the attribute" do
      assert BillingSupport.declares_require_phone?(WithPhone)
    end

    test "is false for a component that does not" do
      refute BillingSupport.declares_require_phone?(WithoutPhone)
    end
  end

  describe "supported?/0" do
    test "agrees with what the installed billing's changeset really does" do
      # A false "no" on a billing that has the option would silently drop the
      # required mark; a false "yes" would pass an attribute nobody declares.
      errors =
        BillingProfile.fields_changeset(
          %BillingProfile{},
          %{"type" => "individual", "first_name" => "A", "last_name" => "B"},
          require_phone: true
        ).errors

      assert BillingSupport.supported?() == Keyword.has_key?(errors, :phone)
    end

    test "the application env overrides the probe" do
      Application.put_env(:phoenix_kit_ecommerce, :billing_require_phone_support, true)
      assert BillingSupport.supported?()

      Application.put_env(:phoenix_kit_ecommerce, :billing_require_phone_support, false)
      refute BillingSupport.supported?()
    end
  end

  describe "phone_attrs/1" do
    test "passes the attribute only when the phone is required and billing supports it" do
      Application.put_env(:phoenix_kit_ecommerce, :billing_require_phone_support, true)
      assert BillingSupport.phone_attrs(true) == [require_phone: true]
      assert BillingSupport.phone_attrs(false) == []

      Application.put_env(:phoenix_kit_ecommerce, :billing_require_phone_support, false)
      assert BillingSupport.phone_attrs(true) == []
    end
  end
end
