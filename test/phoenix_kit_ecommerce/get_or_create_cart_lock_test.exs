defmodule PhoenixKitEcommerce.GetOrCreateCartLockTest do
  @moduledoc """
  `get_or_create_cart/1` now creates under the cart-identity lock and re-checks
  inside it. The result shapes callers match on are unchanged: `{:ok, cart}`
  or `{:error, changeset}`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart

  setup do
    ensure_currencies!()
    :ok
  end

  test "a guest session gets one cart, however often it asks" do
    session = "sess-#{System.unique_integer([:positive])}"

    assert {:ok, first} = Shop.get_or_create_cart(session_id: session)
    assert {:ok, second} = Shop.get_or_create_cart(session_id: session)

    assert first.uuid == second.uuid
    assert Repo.aggregate(from(c in Cart, where: c.session_id == ^session), :count) == 1
  end

  test "a user gets one cart and finds the cart their session started" do
    user = fixture_user()
    session = "sess-#{System.unique_integer([:positive])}"

    assert {:ok, guest} = Shop.get_or_create_cart(session_id: session)
    assert {:ok, again} = Shop.get_or_create_cart(user_uuid: user.uuid, session_id: session)
    assert again.uuid == guest.uuid
  end

  test "a failure to create still comes back as {:error, changeset}" do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(PhoenixKitBilling.Currency)

    assert {:error, %Ecto.Changeset{}} =
             Shop.get_or_create_cart(session_id: "sess-#{System.unique_integer([:positive])}")
  end

  test "the identity lock can be taken twice in one transaction, in any combination" do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               :ok = Shop.lock_cart_identity!(nil, "s1")
               :ok = Shop.lock_cart_identity!(nil, "s1")
               :ok = Shop.lock_cart_identity!("11111111-1111-1111-1111-111111111111", "s1")
               :ok = Shop.lock_cart_identity!("11111111-1111-1111-1111-111111111111", nil)
               Shop.lock_cart_identity!(nil, nil)
             end)
  end
end
