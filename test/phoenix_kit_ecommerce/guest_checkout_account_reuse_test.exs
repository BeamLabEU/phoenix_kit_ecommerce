defmodule PhoenixKitEcommerce.GuestCheckoutAccountReuseTest do
  @moduledoc """
  A guest checkout types an email; that proves nothing about who owns an
  account already holding it. An unconfirmed account somebody registered has
  a password its creator knows, so binding the order to it would show the
  shopper's name and address to whoever signed up with that address first.
  Only an unconfirmed account guest checkout itself created is reused.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.Test.Repo, as: TestRepo

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp guest_cart do
    n = System.unique_integer([:positive])
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Wand #{n}", lang() => "Wand #{n}"},
        "slug" => %{lang() => "guest-reuse-#{n}"},
        "price" => Decimal.new("21.80"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false
      })

    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    cart
  end

  defp billing(email), do: Map.put(complete_billing("US"), "email", email)

  defp unique_email, do: "victim-#{System.unique_integer([:positive])}@example.com"

  test "an unconfirmed REGISTERED account with the typed email does not receive the order" do
    email = unique_email()

    {:ok, squatter} =
      Auth.register_user(%{
        "email" => email,
        "password" => "squatter-password-123",
        "first_name" => "Squat",
        "last_name" => "Ter"
      })

    assert is_nil(squatter.confirmed_at)
    cart = guest_cart()

    assert {:error, :email_already_registered} =
             Shop.convert_cart_to_order(cart, billing_data: billing(email))

    assert PhoenixKitBilling.list_user_orders(squatter.uuid) == []

    # The shopper's name is not written onto the squatter's row either.
    assert %{first_name: "Squat", last_name: "Ter"} = Auth.get_user(squatter.uuid)

    # The cart is untouched, so signing in or using another address completes
    # the same purchase.
    reloaded = TestRepo.get!(Cart, cart.uuid)
    assert reloaded.status == "active"
    assert is_nil(reloaded.user_uuid)

    assert {:ok, order} =
             Shop.convert_cart_to_order(reloaded, billing_data: billing(unique_email()))

    refute order.user_uuid == squatter.uuid
  end

  test "an unconfirmed account guest checkout created is reused by the next guest order" do
    email = unique_email()

    assert {:ok, first} = Shop.convert_cart_to_order(guest_cart(), billing_data: billing(email))
    assert first.user_uuid

    guest = Auth.get_user(first.user_uuid)
    assert is_nil(guest.confirmed_at)
    assert guest.custom_fields["source"] == "guest_checkout"

    assert {:ok, second} = Shop.convert_cart_to_order(guest_cart(), billing_data: billing(email))
    assert second.user_uuid == first.user_uuid
  end
end
