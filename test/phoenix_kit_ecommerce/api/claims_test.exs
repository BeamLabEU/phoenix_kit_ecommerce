defmodule PhoenixKitEcommerce.API.ClaimsTest do
  @moduledoc """
  Issue, peek and redeem of checkout claims: a GET consumes
  nothing, a claim is used once, a changed browser cart is a choice again and
  never two active carts, and the old cart token answers `cart_locked`.
  """

  # async: false - settings are shared.
  use PhoenixKitEcommerce.DataCase, async: false
  @moduletag :requires_core_api

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim

  setup do
    put_secret!()
    ensure_currencies!()
    %{p1: product!(), p2: product!()}
  end

  # An API cart written through the real writer: `lines` is [{product, quantity}].
  defp api_cart!(lines) do
    token = new_token!()
    {:ok, hash} = CartToken.verify(token)

    input = %{
      "items" =>
        Enum.map(lines, fn {product, quantity} ->
          %{"product_id" => product.uuid, "quantity" => quantity, "options" => []}
        end)
    }

    {:ok, _} = CartWriter.set_items(hash, input, ctx_for(token))
    {:ok, cart} = CartStore.resolve(hash)
    %{token: token, hash: hash, cart: cart}
  end

  defp issue!(%{cart: cart, hash: hash}, language \\ "en") do
    {:ok, %{token: raw, claim: claim}} = Claims.issue(cart, hash, language)
    {raw, claim}
  end

  defp browser(user_uuid \\ nil),
    do: %{session_id: "browser-#{System.unique_integer([:positive])}", user_uuid: user_uuid}

  defp browser_cart!(%{session_id: sid}, lines, currency \\ nil) do
    PhoenixKitBilling.Currency.put_request_currency(currency)
    {:ok, cart} = Shop.create_cart(session_id: sid)
    PhoenixKitBilling.Currency.put_request_currency(nil)

    Enum.reduce(lines, cart, fn {product, quantity}, acc ->
      {:ok, updated} = Shop.add_to_cart(acc, product, quantity)
      updated
    end)
  end

  defp active_carts(session_id),
    do: Repo.all(from c in Cart, where: c.status == "active" and c.session_id == ^session_id)

  defp redeem(raw, browser, offer, choice \\ nil),
    do: Claims.redeem(raw, browser, %{offer: offer, choice: choice})

  defp quantities(cart), do: cart.items |> Enum.map(& &1.quantity) |> Enum.sort()

  # After a hand-off (moved, replaced or merged) the old token must answer
  # cart_locked to a write, never write into the buyer's cart.
  defp assert_write_locked(api, product) do
    input = %{"items" => [%{"product_id" => product.uuid, "quantity" => 3}]}

    assert {:error, :cart_locked, _message, %{}} =
             CartWriter.set_items(api.hash, input, ctx_for(api.token))
  end

  describe "issue/3" do
    test "stores the digest of a fresh token, not the token, with the configured lifetime", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)

      assert byte_size(raw) == 43
      assert claim.token_hash == CartToken.digest(raw)
      refute claim.token_hash == raw
      assert claim.cart_token_hash == api.hash
      assert claim.language == "en"
      assert claim.used_at == nil and claim.superseded_at == nil

      now = DateTime.utc_now()
      assert DateTime.diff(claim.expires_at, now) in 1790..1810

      put_setting!("api_checkout_claim_ttl_minutes", 5)
      {_raw2, claim2} = issue!(api)
      assert DateTime.diff(claim2.expires_at, DateTime.utc_now()) in 290..310
    end

    test "a new link supersedes every earlier unused claim of the cart", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {first, _} = issue!(api)
      {second, _} = issue!(api)

      assert {:error, :superseded} = Claims.peek(first)
      assert {:ok, %{cart: cart}} = Claims.peek(second)
      assert cart.uuid == api.cart.uuid
      assert Repo.aggregate(from(k in CartClaim, where: is_nil(k.superseded_at)), :count) == 1
    end

    # One token can ask for a link about 120 times a minute; without a bound
    # that is a row each, kept until 7 days after expiry.
    test "the table stays bounded: the live link and the one it just replaced, nothing older",
         ctx do
      api = api_cart!([{ctx.p1, 1}])
      links = for _ <- 1..5, do: elem(issue!(api), 0)

      assert Repo.aggregate(from(k in CartClaim, where: k.cart_uuid == ^api.cart.uuid), :count) ==
               2

      assert {:ok, _} = Claims.peek(List.last(links))
      assert {:error, :superseded} = Claims.peek(Enum.at(links, 3))
      assert {:error, :invalid} = Claims.peek(hd(links))
    end
  end

  describe "peek/1" do
    test "reads, and never consumes, however often it is called", ctx do
      api = api_cart!([{ctx.p1, 2}])
      {raw, claim} = issue!(api)

      for _ <- 1..5 do
        assert {:ok, %{claim: found}} = Claims.peek(raw)
        assert found.uuid == claim.uuid
      end

      assert Repo.get!(CartClaim, claim.uuid).used_at == nil
    end

    test "answers invalid for an unknown, short or huge token" do
      for bad <- ["", "x", String.duplicate("a", 43), String.duplicate("b", 5000)] do
        assert {:error, :invalid} = Claims.peek(bad)
      end
    end

    test "answers expired, used and cart_unavailable", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)

      claim
      |> Ecto.Changeset.change(
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert {:error, :expired} = Claims.peek(raw)

      other = api_cart!([{ctx.p1, 1}])
      {raw2, claim2} = issue!(other)

      claim2
      |> Ecto.Changeset.change(used_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      assert {:error, :used} = Claims.peek(raw2)

      third = api_cart!([{ctx.p1, 1}])
      {raw3, _} = issue!(third)
      third.cart |> Cart.status_changeset("abandoned") |> Repo.update!()
      assert {:error, :cart_unavailable} = Claims.peek(raw3)
    end
  end

  describe "redeem/3 when the browser has no cart" do
    test "moves the API cart to the browser's session and locks the old token", ctx do
      api = api_cart!([{ctx.p1, 2}, {ctx.p2, 1}])
      {raw, claim} = issue!(api, "de")
      browser = browser()

      assert {:ok, %{language: "de", skipped: [], mode: :moved}} = redeem(raw, browser, "none")

      assert [cart] = active_carts(browser.session_id)
      assert cart.uuid == api.cart.uuid
      assert Repo.get!(CartClaim, claim.uuid).used_at != nil
      assert {:locked, %CartClaim{}} = CartStore.resolve(api.hash)
      assert {:error, :used} = redeem(raw, browser, "none")

      assert {:error, :cart_locked, _message, %{}} =
               CartWriter.set_items(
                 api.hash,
                 %{"items" => [%{"product_id" => ctx.p1.uuid, "quantity" => 3}]},
                 ctx_for(api.token)
               )
    end

    test "an empty cart of the browser is abandoned, so there is never a second active cart",
         ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      empty = browser_cart!(browser, [])

      assert {:ok, %{mode: :moved}} = redeem(raw, browser, "none")

      assert Repo.get!(Cart, empty.uuid).status == "abandoned"
      assert [%Cart{uuid: uuid}] = active_carts(browser.session_id)
      assert uuid == api.cart.uuid
    end

    test "a logged-in buyer's cart is found by user", ctx do
      user = fixture_user()
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser(user.uuid)

      assert {:ok, %{mode: :moved}} = redeem(raw, browser, "none")

      found = Shop.find_active_cart(user_uuid: user.uuid, session_id: browser.session_id)
      assert found.uuid == api.cart.uuid
    end
  end

  describe "redeem/3 when the browser already has a cart" do
    test "replace abandons the browser's cart and moves the API cart", ctx do
      api = api_cart!([{ctx.p1, 2}])
      {raw, _} = issue!(api)
      browser = browser()
      old = browser_cart!(browser, [{ctx.p2, 1}])

      assert {:ok, %{mode: :replaced, skipped: []}} = redeem(raw, browser, old.uuid, "replace")

      assert Repo.get!(Cart, old.uuid).status == "abandoned"
      assert [cart] = active_carts(browser.session_id)
      assert cart.uuid == api.cart.uuid
      assert {:locked, %CartClaim{}} = CartStore.resolve(api.hash)
      assert_write_locked(api, ctx.p1)
    end

    test "add merges the lines into the browser's cart and marks the API cart merged", ctx do
      api = api_cart!([{ctx.p1, 5}, {ctx.p2, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p1, 98}])

      assert {:ok, %{mode: :merged, skipped: []}} = redeem(raw, browser, mine.uuid, "add")

      assert [cart] = active_carts(browser.session_id)
      assert cart.uuid == mine.uuid
      cart = Shop.get_cart(cart.uuid)
      assert quantities(cart) == [1, 99]

      merged = Repo.get!(Cart, api.cart.uuid)
      assert merged.status == "merged"
      assert merged.merged_into_cart_uuid == mine.uuid
      assert {:locked, %CartClaim{}} = CartStore.resolve(api.hash)
      assert_write_locked(api, ctx.p1)
    end

    test "add re-prices in the browser cart's currency and keeps its shipping choice", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p2, 1}], "EUR")

      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Post",
          "price" => Decimal.new("3.00"),
          "active" => true
        })

      {:ok, _} = Shop.set_cart_shipping(Shop.get_cart(mine.uuid), method, "DE")

      assert {:ok, %{mode: :merged}} = redeem(raw, browser, mine.uuid, "add")

      cart = Shop.get_cart(mine.uuid)
      assert cart.shipping_method_uuid == method.uuid
      added = Enum.find(cart.items, &(&1.product_uuid == ctx.p1.uuid))
      assert added.currency == "EUR"
      assert Decimal.compare(added.unit_price, Decimal.new("10.00")) == :lt
    end

    test "add skips a line that no longer validates and returns its title", ctx do
      api = api_cart!([{ctx.p1, 1}, {ctx.p2, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{product!(), 1}])
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      assert {:ok, %{mode: :merged, skipped: [title]}} = redeem(raw, browser, mine.uuid, "add")

      assert title =~ "Widget"
      assert length(Shop.get_cart(mine.uuid).items) == 2
    end

    test "add skips a line that add_to_cart refuses for good, and keeps the others", ctx do
      foreign = product!(%{"currency" => "EUR"})
      api = api_cart!([{ctx.p1, 1}, {foreign, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p2, 1}])
      put_setting!("shop_enforce_product_currency", true)

      assert {:ok, %{mode: :merged, skipped: [title]}} = redeem(raw, browser, mine.uuid, "add")

      assert title == foreign.title["en"]
      assert [_, _] = Shop.get_cart(mine.uuid).items
      refute Enum.any?(Shop.get_cart(mine.uuid).items, &(&1.product_uuid == foreign.uuid))
      assert Repo.get!(Cart, api.cart.uuid).status == "merged"
    end
  end

  describe "redeem/3 when the choice is stale or missing" do
    test "a browser cart with items and no choice shows the choice again, nothing changes", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p2, 1}])

      for choice <- [nil, "continue", "merge", ""] do
        assert {:error, :reshow} = redeem(raw, browser, mine.uuid, choice)
      end

      assert Repo.get!(CartClaim, claim.uuid).used_at == nil
      assert Repo.get!(Cart, api.cart.uuid).session_id == "api:" <> api.hash
      assert [%Cart{uuid: uuid}] = active_carts(browser.session_id)
      assert uuid == mine.uuid
    end

    test "a cart that appeared after the page was shown is a choice again", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      _appeared = browser_cart!(browser, [{ctx.p2, 1}])

      assert {:error, :reshow} = redeem(raw, browser, "none")
      assert [_one] = active_carts(browser.session_id)
    end

    test "a cart that was emptied or replaced after the page was shown is a choice again", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p2, 1}])

      assert {:error, :reshow} = redeem(raw, browser, Ecto.UUID.generate(), "replace")
      assert {:error, :reshow} = redeem(raw, browser, "", "replace")

      {:ok, _} = Shop.clear_cart(Shop.get_cart(mine.uuid))
      assert {:error, :reshow} = redeem(raw, browser, mine.uuid, "replace")
    end

    test "a claim is used once; superseded, expired and unknown claims move nothing", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {first, _} = issue!(api)
      {second, claim2} = issue!(api)
      browser = browser()

      assert {:error, :superseded} = redeem(first, browser, "none")
      assert {:error, :invalid} = redeem("nope", browser, "none")
      assert Repo.get!(Cart, api.cart.uuid).session_id == "api:" <> api.hash

      claim2
      |> Ecto.Changeset.change(
        expires_at: DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert {:error, :expired} = redeem(second, browser, "none")
      assert active_carts(browser.session_id) == []
    end

    test "a cart swept between the page and the POST is unavailable", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      api.cart |> Cart.status_changeset("abandoned") |> Repo.update!()

      assert {:error, :cart_unavailable} = redeem(raw, browser(), "none")
    end
  end

  describe "helpers" do
    test "path/1 is outside the locale prefix and carries the token", ctx do
      {raw, _} = issue!(api_cart!([{ctx.p1, 1}]))

      assert Claims.path(raw) == "/checkout/claim/" <> raw
    end

    test "language_of/1 reads the claim's language without consuming it", ctx do
      {raw, claim} = issue!(api_cart!([{ctx.p1, 1}]), "fr")

      assert Claims.language_of(raw) == "fr"
      assert Claims.language_of("nope") == nil
      assert Repo.get!(CartClaim, claim.uuid).used_at == nil
    end
  end
end
