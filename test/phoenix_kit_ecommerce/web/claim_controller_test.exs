defmodule PhoenixKitEcommerce.Web.ClaimControllerTest do
  @moduledoc """
  The buyer's side of the hand-off: GET consumes nothing and shows the right
  choice; POST needs the CSRF token, consumes once, and every dead end is a
  redirect with a notice, never an error page.
  """

  # async: false - the signing secret and settings are shared.
  use PhoenixKitEcommerce.LiveCase, async: false
  @moduletag :requires_core_api

  import Ecto.Query
  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim
  alias PhoenixKitEcommerce.Test.Repo

  setup %{conn: conn} do
    put_secret!()
    ensure_currencies!()

    session = "browser-#{System.unique_integer([:positive])}"
    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session})
    p1 = product!()
    p2 = product!()

    token = new_token!()
    {:ok, hash} = CartToken.verify(token)

    {:ok, _} =
      CartWriter.set_items(
        hash,
        %{
          "items" => [
            %{"product_id" => p1.uuid, "quantity" => 2},
            %{"product_id" => p2.uuid, "quantity" => 1}
          ]
        },
        ctx_for(token)
      )

    {:ok, cart} = CartStore.resolve(hash)
    {:ok, %{token: raw, claim: claim}} = Claims.issue(cart, hash, "en")

    %{
      conn: conn,
      session: session,
      raw: raw,
      claim: claim,
      api_cart: cart,
      hash: hash,
      p1: p1,
      p2: p2
    }
  end

  defp page(conn, raw), do: get(conn, Claims.path(raw))

  defp csrf_token(html) do
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html)
    token
  end

  defp active_carts(session),
    do: Repo.all(from c in Cart, where: c.status == "active" and c.session_id == ^session)

  defp active_carts_of(user),
    do: Repo.all(from c in Cart, where: c.status == "active" and c.user_uuid == ^user.uuid)

  # `updated_at` has second precision: make "the newest cart" unambiguous.
  defp newest!(cart) do
    later = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [updated_at: later])
  end

  defp signed_in(conn, user),
    do: Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => %{user: user}})

  describe "GET" do
    test "shows the lines and one button, and consumes nothing however often it is opened", ctx do
      html =
        Enum.reduce(1..4, nil, fn _, _ ->
          conn = page(ctx.conn, ctx.raw)
          assert conn.status == 200
          assert ["no-referrer"] = get_resp_header(conn, "referrer-policy")
          assert ["no-store" <> _] = get_resp_header(conn, "cache-control")
          assert ["noindex, nofollow"] = get_resp_header(conn, "x-robots-tag")
          html_response(conn, 200)
        end)

      assert html =~ ~s(id="claim-page")
      assert html =~ ~s(id="claim-lines")
      assert html =~ ~s(id="claim-continue")
      assert html =~ ~s(name="offer" value="none")
      assert html =~ ctx.p1.title["en"]
      refute html =~ ~s(id="claim-replace")
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
    end

    test "offers replace and add when the browser already has a cart with items", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      html = ctx.conn |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(id="claim-replace")
      assert html =~ ~s(id="claim-add")
      refute html =~ ~s(id="claim-continue")
      assert html =~ ~s(name="offer" value="#{mine.uuid}")
    end

    test "an empty cart of the browser is not a choice", ctx do
      {:ok, _empty} = Shop.create_cart(session_id: ctx.session)

      html = ctx.conn |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(id="claim-continue")
    end

    test "a logged-in buyer who owns a cart with lines is offered it", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()
      {:ok, mine} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      html = ctx.conn |> signed_in(user) |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(id="claim-add")
      assert html =~ ~s(id="claim-replace")
      refute html =~ ~s(id="claim-continue")
      assert html =~ ~s(name="offer" value="#{mine.uuid}")
    end

    # Two definitions of "the browser's cart" would show here: the page offers
    # nothing (the user's cart is empty), the POST finds the newer guest cart.
    test "the page offers the cart a POST will compare against", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()
      {:ok, _empty} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, guest} = Shop.create_cart(session_id: ctx.session)
      {:ok, guest} = Shop.add_to_cart(guest, product!(), 1)
      newest!(guest)

      conn = signed_in(ctx.conn, user)
      html = conn |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(name="offer" value="#{guest.uuid}")

      stale = post(conn, Claims.path(ctx.raw), %{"offer" => "none"})
      assert redirected_to(stale) == Claims.path(ctx.raw)
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
    end

    test "two active carts of the browser never make an error page", ctx do
      {:ok, _first} = Shop.create_cart(session_id: ctx.session)
      {:ok, second} = Shop.create_cart(session_id: ctx.session)
      {:ok, second} = Shop.add_to_cart(second, product!(), 1)
      newest!(second)

      html = ctx.conn |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(name="offer" value="#{second.uuid}")
    end

    test "speaks the claim's language", ctx do
      {:ok, %{token: german}} = Claims.issue(ctx.api_cart, ctx.hash, "de")

      conn = page(ctx.conn, german)
      html = html_response(conn, 200)

      assert html =~ "Weiter zur Kasse"
      assert conn.assigns.content_language == "de"
      assert html =~ "Ein Assistent hat diesen Warenkorb"
    end

    test "unknown, superseded and expired links go to the cart page with a notice", ctx do
      {:ok, %{token: newer}} = Claims.issue(ctx.api_cart, ctx.hash, "en")

      expired =
        Repo.get!(
          CartClaim,
          Repo.one(from k in CartClaim, where: is_nil(k.superseded_at), select: k.uuid)
        )

      expired
      |> Ecto.Changeset.change(
        expires_at: DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      for raw <- ["nope-not-a-real-token", ctx.raw, newer] do
        conn = page(ctx.conn, raw)

        assert redirected_to(conn) == Shop.cart_url("en"), inspect(raw)
        assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "already been used or has expired"
      end
    end

    test "a shop that is switched off is not touched", ctx do
      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")

      conn = page(ctx.conn, ctx.raw)

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "currently unavailable"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
    end
  end

  describe "POST" do
    test "continue moves the cart to the browser and goes to checkout", ctx do
      conn = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => "none"})

      assert redirected_to(conn) == Shop.checkout_url("en")
      assert [cart] = active_carts(ctx.session)
      assert cart.uuid == ctx.api_cart.uuid
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at != nil
      assert {:locked, %CartClaim{}} = CartStore.resolve(ctx.hash)
    end

    test "a second POST claims nothing again and shows the cart page", ctx do
      first = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => "none"})
      assert redirected_to(first) == Shop.checkout_url("en")
      used_at = Repo.get!(CartClaim, ctx.claim.uuid).used_at

      second = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => "none"})

      assert redirected_to(second) == Shop.cart_url("en")
      assert Phoenix.Flash.get(second.assigns.flash, :info) =~ "already been used or has expired"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == used_at
      assert [_one] = active_carts(ctx.session)
    end

    test "a browser cart that appeared after the page was shown sends the buyer back to the choice",
         ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, _mine} = Shop.add_to_cart(mine, product!(), 1)

      conn = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => "none"})

      assert redirected_to(conn) == Claims.path(ctx.raw)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Please choose again"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
      assert [still_mine] = active_carts(ctx.session)
      refute still_mine.uuid == ctx.api_cart.uuid
    end

    test "replace abandons the buyer's cart and leaves exactly one active cart", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      replace =
        post(ctx.conn, Claims.path(ctx.raw), %{"offer" => mine.uuid, "choice" => "replace"})

      assert redirected_to(replace) == Shop.checkout_url("en")
      assert [only] = active_carts(ctx.session)
      assert only.uuid == ctx.api_cart.uuid
      assert Repo.get!(Cart, mine.uuid).status == "abandoned"
    end

    test "add merges, and names the lines it had to skip", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      conn = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => mine.uuid, "choice" => "add"})

      assert redirected_to(conn) == Shop.checkout_url("en")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer available"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Widget"
      assert [only] = active_carts(ctx.session)
      assert only.uuid == mine.uuid
      assert Repo.get!(Cart, ctx.api_cart.uuid).status == "merged"
    end

    test "junk parameters are a choice again, never a crash", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      for params <- [
            %{},
            %{"offer" => ["x"]},
            %{"offer" => mine.uuid, "choice" => ["add"]},
            %{"offer" => mine.uuid, "choice" => "steal"}
          ] do
        conn = post(ctx.conn, Claims.path(ctx.raw), params)
        assert redirected_to(conn) == Claims.path(ctx.raw), inspect(params)
      end

      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
    end

    test "is refused without the CSRF token and accepted with it", ctx do
      page_conn = page(ctx.conn, ctx.raw)
      token = csrf_token(html_response(page_conn, 200))

      refused =
        page_conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent 403, fn -> post(refused, Claims.path(ctx.raw), %{"offer" => "none"}) end
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil

      accepted =
        page_conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> post(Claims.path(ctx.raw), %{"offer" => "none", "_csrf_token" => token})

      assert redirected_to(accepted) == Shop.checkout_url("en")
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at != nil
    end

    test "a logged-in buyer receives the claimed cart as their own", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()

      response =
        ctx.conn |> signed_in(user) |> post(Claims.path(ctx.raw), %{"offer" => "none"})

      assert redirected_to(response) == Shop.checkout_url("en")
      assert [found] = active_carts_of(user)
      assert found.uuid == ctx.api_cart.uuid
      assert found.user_uuid == user.uuid
      assert found.expires_at == nil
    end

    test "a logged-in buyer who owns a cart ends with exactly one active cart, either way", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()
      {:ok, mine} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)
      conn = signed_in(ctx.conn, user)

      replaced =
        post(conn, Claims.path(ctx.raw), %{"offer" => mine.uuid, "choice" => "replace"})

      assert redirected_to(replaced) == Shop.checkout_url("en")
      assert [only] = active_carts_of(user)
      assert only.uuid == ctx.api_cart.uuid
      assert Repo.get!(Cart, mine.uuid).status == "abandoned"
    end

    test "a logged-in buyer who adds keeps their own cart as the only active one", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()
      {:ok, mine} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      added =
        ctx.conn
        |> signed_in(user)
        |> post(Claims.path(ctx.raw), %{"offer" => mine.uuid, "choice" => "add"})

      assert redirected_to(added) == Shop.checkout_url("en")
      assert [only] = active_carts_of(user)
      assert only.uuid == mine.uuid
      assert Repo.get!(Cart, ctx.api_cart.uuid).status == "merged"
    end

    test "a shop that is switched off consumes nothing", ctx do
      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")

      conn = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => "none"})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "currently unavailable"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
      assert Repo.get!(Cart, ctx.api_cart.uuid).status == "active"
      assert Repo.get!(Cart, ctx.api_cart.uuid).session_id == "api:" <> ctx.hash
    end

    # A trigger raises what Postgres raises for the aborted side of a deadlock
    # (SQLSTATE 40P01); the DDL rolls back with the test's transaction.
    test "a deadlock victim goes back to the choice, with nothing claimed", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      Repo.query!("""
      CREATE FUNCTION pk_test_raise_deadlock() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'simulated deadlock' USING ERRCODE = '40P01'; END
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER pk_test_raise_deadlock BEFORE INSERT ON phoenix_kit_shop_cart_items
      FOR EACH ROW EXECUTE FUNCTION pk_test_raise_deadlock()
      """)

      conn = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => mine.uuid, "choice" => "add"})

      assert redirected_to(conn) == Claims.path(ctx.raw)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Your cart was not changed"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
      assert Repo.get!(Cart, ctx.api_cart.uuid).status == "active"
    end
  end
end
