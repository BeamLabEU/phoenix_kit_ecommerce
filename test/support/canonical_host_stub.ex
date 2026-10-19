defmodule PhoenixKitEcommerce.Test.CanonicalHostStub do
  @moduledoc false

  def host("de"), do: "shop.example.de"
  def host("fr"), do: "shop.example.fr"
  def host(_language), do: nil
end
