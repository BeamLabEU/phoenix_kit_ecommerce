defmodule PhoenixKitEcommerce.ShopifyEnabledReadErrorTest do
  @moduledoc """
  `shopify_enabled?/0` fails closed. This module deliberately does not use
  `DataCase`: with no sandbox connection checked out, every database read
  fails, which is the "settings read error" case.
  """

  use ExUnit.Case, async: false

  test "a failing settings read answers false, not true" do
    refute PhoenixKitEcommerce.shopify_enabled?()
  end
end
