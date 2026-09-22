defmodule PhoenixKitEcommerce.CategoryTreeLockTest do
  @moduledoc """
  A category re-parent holds the shop's category-tree lock through its
  cycle check, so two in opposite directions at once cannot both pass and
  commit a loop. The sandbox runs every test on one connection and cannot
  race, so this holds the lock from a second, real connection and watches
  a re-parent wait.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.Repo

  @key "phoenix_kit_ecommerce:category_tree"

  defp holder do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
    # Linked: it ends with the test, releasing whatever it still holds.
    {:ok, conn} = Postgrex.start_link(opts)
    conn
  end

  defp category!(name) do
    {:ok, category} = Shop.create_category(%{name: %{"en" => name}})
    category
  end

  test "a re-parent waits for the category-tree lock; a rename does not" do
    [a, b] = [category!("A"), category!("B")]
    conn = holder()
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [@key])

    assert {:ok, a} = Shop.update_category(a, %{name: %{"en" => "A2"}})

    move = Task.async(fn -> Shop.update_category(a, %{parent_uuid: b.uuid}) end)
    assert Task.yield(move, 300) == nil

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [@key])
    assert {:ok, moved} = Task.await(move)
    assert moved.parent_uuid == b.uuid
  end
end
