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

  describe "GET" do
    test "shows the lines and one button, and consumes nothing however often it is opened", ctx do
      html =
        Enum.reduce(1..4, nil, fn _, _ ->
          conn = page(ctx.conn, ctx.raw)
          assert conn.status == 200
          assert ["no-referrer"] = get_resp_header(conn, "referrer-policy")
          assert ["no-store" <> _] = get_resp_header(conn, "cache-control")
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

    test "speaks the claim's language", ctx do
      {:ok, %{token: german}} = Claims.issue(ctx.api_cart, ctx.hash, "de")

      html = ctx.conn |> page(german) |> html_response(200)

      assert html =~ "Weiter zur Kasse"
      assert html =~ "Ein Assistent hat diesen Warenkorb"
    end

    test "unknown, used, superseded and expired links go to the cart page with a notice", ctx do
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

    test "a logged-in buyer's cart is found by user", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()
      conn = Plug.Test.init_test_session(ctx.conn, %{"phoenix_kit_test_scope" => %{user: user}})

      response = post(conn, Claims.path(ctx.raw), %{"offer" => "none"})

      assert redirected_to(response) == Shop.checkout_url("en")
      found = Shop.find_active_cart(user_uuid: user.uuid, session_id: ctx.session)
      assert found.uuid == ctx.api_cart.uuid
    end
  end
end
