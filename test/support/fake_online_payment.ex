defmodule PhoenixKitEcommerce.Test.FakeOnlinePayment do
  @moduledoc """
  Stand-in for `PhoenixKitBilling.start_order_payment/2` in the online-payment
  tests, so they run the same on a billing that lacks it. Point
  `PhoenixKitEcommerce.OnlinePayment` at it with `put_result/1`; every call is
  sent to the process that set it up as `{:start_order_payment, order, opts}`.
  `reset/0` removes the override (the real billing module is used again).
  """

  @env_key :online_payment_module
  @result_key :fake_online_payment_result
  @owner_key :fake_online_payment_owner

  @doc "Uses the fake and makes it answer `result` (an `{:ok, _}` or `{:error, _}`)."
  def put_result(result) do
    Application.put_env(:phoenix_kit_ecommerce, @env_key, __MODULE__)
    Application.put_env(:phoenix_kit_ecommerce, @result_key, result)
    Application.put_env(:phoenix_kit_ecommerce, @owner_key, self())
  end

  @doc "Uses a billing module without `start_order_payment/2` (an older billing)."
  def put_old_billing do
    Application.put_env(:phoenix_kit_ecommerce, @env_key, PhoenixKitEcommerce.Test.OldBilling)
  end

  def reset do
    Application.delete_env(:phoenix_kit_ecommerce, @env_key)
    Application.delete_env(:phoenix_kit_ecommerce, @result_key)
    Application.delete_env(:phoenix_kit_ecommerce, @owner_key)
  end

  def start_order_payment(order, opts) do
    if owner = Application.get_env(:phoenix_kit_ecommerce, @owner_key),
      do: send(owner, {:start_order_payment, order, opts})

    Application.get_env(:phoenix_kit_ecommerce, @result_key, {:error, :not_set})
  end
end

defmodule PhoenixKitEcommerce.Test.OldBilling do
  @moduledoc "A billing module as old releases are: no `start_order_payment/2`."
end
