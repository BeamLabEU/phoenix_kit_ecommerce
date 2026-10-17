defmodule PhoenixKitEcommerce.API.ExecutorTest do
  @moduledoc """
  The four e-commerce tools through core's real `Executor.call/4`, as the REST
  plug calls it: a real user with real role permissions, a real key, the real
  scope check, the real danger gate. What `APICase` leaves out is exactly
  what is checked here: authentication, the scope refusal, the schema as the
  executor closes it, and for `set_prices` the whole confirmation round
  (a preview with a code, then the same call with the code).

  One success, one validation error and one scope refusal per tool.
  `async: false`: it registers a key cache, flips settings and uses the
  shop-wide rate limiter.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api
  @moduletag :core_confirm

  @compile {:no_warn_undefined,
            [
              PhoenixKit.API.Auth,
              PhoenixKit.API.Executor,
              PhoenixKit.API.Keys,
              PhoenixKit.API.Keys.Cache,
              PhoenixKit.Cache,
              PhoenixKit.Cache.Registry,
              PhoenixKit.Users.Auth.Scope,
              PhoenixKit.Users.Permissions,
              PhoenixKit.Users.Roles
            ]}

  import Plug.Conn

  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Keys
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitEcommerce.APIFixtures, as: F

  @read "ecommerce.prices:read"
  @prices "ecommerce.prices:write"
  @availability "ecommerce.availability:write"
  @images "ecommerce.images:write"
  @all [@read, @prices, @availability, @images]

  setup do
    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :api_keys, ttl: :timer.seconds(60)})
    start_supervised!(PhoenixKit.API.Keys.Cache)

    shop = Settings.get_boolean_setting("shop_enabled", false)

    # Core signs confirmation codes with the application's secret; this package
    # has no endpoint of its own to take one from.
    secret = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("c", 64))

    on_exit(fn ->
      if secret,
        do: Application.put_env(:phoenix_kit, :secret_key_base, secret),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)

      Settings.update_boolean_setting_with_module("shop_enabled", shop, "shop")

      Settings.update_boolean_setting_with_module(
        "shop_image_import_allow_private_networks",
        false,
        "shop"
      )
    end)

    {:ok, _} = Settings.update_boolean_setting("api_admin_enabled", true)
    {:ok, _} = Settings.update_boolean_setting_with_module("shop_enabled", true, "shop")

    owner = owner_with(["shop", "shop.manage_catalog"])
    {_key, token} = issue_key(owner, @all)

    %{catalogue: F.shop_catalogue!(), owner: owner, token: token}
  end

  # -- real users, keys and requests ------------------------------------------

  defp owner_with(permissions) do
    {:ok, role} = Roles.create_role(%{name: "EcomApi#{System.unique_integer([:positive])}"})
    for key <- ["api" | permissions], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = F.user!()
    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  # A key created by its owner with the owner's own scope, as the settings page does.
  defp issue_key(owner, scopes) do
    scope = Scope.for_user(owner, narrow: false)
    {:ok, key, token} = Keys.create_key(owner, scope, %{name: "ecom api", scopes: scopes})
    {key, token}
  end

  # A request from an address no other test uses (the rate-limit counters are shared).
  defp authed(token) do
    n = System.unique_integer([:positive])
    peer = {10, rem(n, 250) + 1, rem(div(n, 250), 250) + 1, rem(div(n, 62_500), 250) + 1}

    :post
    |> Plug.Test.conn("/")
    |> Map.put(:remote_ip, peer)
    |> put_req_header("authorization", "Bearer " <> token)
    |> Auth.call(Auth.init(audience: :admin))
  end

  defp call(token, tool, input), do: Executor.call(authed(token), :admin, tool, input)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp read_only_token(owner, scope) do
    {_key, token} = issue_key(owner, [scope])
    token
  end

  # -- ecommerce.get_prices ---------------------------------------------------

  describe "ecommerce.get_prices" do
    test "answers the price of a product", %{catalogue: catalogue, token: token} do
      item = F.item!(catalogue, %{base_price: Decimal.new("35.52")})

      conn = call(token, "ecommerce.get_prices", %{"refs" => [%{"id" => item.uuid}]})

      assert conn.status == 200
      assert %{"results" => [row], "summary" => %{"found" => 1}} = json(conn)
      assert row["id"] == item.uuid
      assert row["price"]["amount"] == "35.52"
    end

    test "refuses an input the closed schema does not accept with 422", %{token: token} do
      conn = call(token, "ecommerce.get_prices", %{"refs" => []})

      assert conn.status == 422
      assert json(conn)["code"] == "validation_failed"
    end

    test "refuses a key that holds another scope with 403", %{owner: owner} do
      token = read_only_token(owner, @images)

      conn = call(token, "ecommerce.get_prices", %{"refs" => [%{"sku" => "X"}]})

      assert conn.status == 403
      assert %{"code" => "forbidden", "context" => %{"required_scope" => @read}} = json(conn)
    end
  end

  # -- ecommerce.set_prices ---------------------------------------------------

  describe "ecommerce.set_prices" do
    test "writes a small move at once", %{catalogue: catalogue, token: token} do
      item = F.item!(catalogue)

      conn =
        call(token, "ecommerce.set_prices", %{
          "items" => [%{"ref" => %{"id" => item.uuid}, "price" => "110.00"}]
        })

      assert conn.status == 200
      assert %{"summary" => %{"updated" => 1}} = json(conn)
      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("110.00"))
    end

    test "refuses a price a client could mean differently with 422 and the path", %{
      catalogue: catalogue,
      token: token
    } do
      item = F.item!(catalogue)

      conn =
        call(token, "ecommerce.set_prices", %{
          "items" => [%{"ref" => %{"id" => item.uuid}, "price" => "12,50"}]
        })

      assert conn.status == 422
      assert %{"code" => "validation_failed"} = json(conn)
      assert inspect(json(conn)) =~ "items[0].price"
      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("100.00"))
    end

    test "refuses a key without the write scope with 403 and writes nothing", %{
      catalogue: catalogue,
      owner: owner
    } do
      item = F.item!(catalogue)
      token = read_only_token(owner, @read)

      conn =
        call(token, "ecommerce.set_prices", %{
          "items" => [%{"ref" => %{"id" => item.uuid}, "price" => "110.00"}]
        })

      assert conn.status == 403
      assert json(conn)["context"]["required_scope"] == @prices
      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("100.00"))
    end

    test "a move above the threshold is previewed, then applied with its confirmation code", %{
      catalogue: catalogue,
      token: token
    } do
      item = F.item!(catalogue)
      input = %{"items" => [%{"ref" => %{"id" => item.uuid}, "price" => "200.00"}]}

      first = call(token, "ecommerce.set_prices", input)

      assert first.status == 200

      assert %{"executed" => false, "status" => "confirmation_required", "confirm_token" => code} =
               json(first)

      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("100.00"))

      confirmed = call(token, "ecommerce.set_prices", Map.put(input, "confirm_token", code))

      assert confirmed.status == 200
      assert %{"summary" => %{"updated" => 1}} = json(confirmed)
      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("200.00"))
    end
  end

  describe "the dry run of a tool with a danger rule" do
    test "creates no code, and the real call is held exactly when the preview said so", %{
      catalogue: catalogue,
      token: token
    } do
      for {price, held?} <- [{"110.00", false}, {"0", true}, {"1000.00", true}, {"69.00", true}] do
        item = F.item!(catalogue)
        input = %{"items" => [%{"ref" => %{"id" => item.uuid}, "price" => price}]}

        dry = call(token, "ecommerce.set_prices", Map.put(input, "dry_run", true))

        assert dry.status == 200
        assert %{"executed" => false, "dry_run" => true, "preview" => preview} = json(dry)
        assert preview["requires_confirmation"] == held?
        refute Map.has_key?(json(dry), "confirm_token")

        real = call(token, "ecommerce.set_prices", input)

        assert real.status == 200
        assert json(real)["executed"] == false == held?, "price #{price}"
      end
    end

    test "a batch over core's row threshold: the preview says held and the real call is", %{
      catalogue: catalogue,
      token: token
    } do
      previous = Settings.get_setting("api_confirm_batch_over")
      {:ok, _} = Settings.update_setting("api_confirm_batch_over", "2")
      on_exit(fn -> Settings.update_setting("api_confirm_batch_over", previous || "50") end)

      for count <- [2, 3] do
        rows =
          for _ <- 1..count,
              do: %{"ref" => %{"id" => F.item!(catalogue).uuid}, "price" => "101.00"}

        input = %{"items" => rows}
        dry = call(token, "ecommerce.set_prices", Map.put(input, "dry_run", true))
        held? = json(dry)["preview"]["requires_confirmation"]
        assert held? == (count == 3)

        real = call(token, "ecommerce.set_prices", input)
        assert json(real)["executed"] == false == held?
      end
    end
  end

  # -- ecommerce.set_availability ---------------------------------------------

  describe "ecommerce.set_availability" do
    test "hides a product", %{catalogue: catalogue, token: token} do
      item = F.item!(catalogue)

      conn =
        call(token, "ecommerce.set_availability", %{
          "items" => [%{"ref" => %{"id" => item.uuid}, "visibility" => "archived"}]
        })

      assert conn.status == 200
      assert %{"summary" => %{"updated" => 1}} = json(conn)
      assert F.reload!(item).data["ecommerce"]["shop_status"] == "archived"
    end

    test "a batch above core's row threshold is held for confirmation and writes nothing", %{
      catalogue: catalogue,
      token: token
    } do
      previous = Settings.get_setting("api_confirm_batch_over")
      {:ok, _} = Settings.update_setting("api_confirm_batch_over", "2")
      on_exit(fn -> Settings.update_setting("api_confirm_batch_over", previous || "50") end)

      items = for _ <- 1..3, do: F.item!(catalogue)

      input = %{
        "items" =>
          for(item <- items, do: %{"ref" => %{"id" => item.uuid}, "visibility" => "archived"})
      }

      conn = call(token, "ecommerce.set_availability", input)

      assert conn.status == 200
      assert %{"executed" => false, "status" => "confirmation_required"} = json(conn)

      for item <- items,
          do: assert(F.reload!(item).data["ecommerce"]["shop_status"] == "active")
    end

    test "refuses a visibility that is not offered with 422", %{
      catalogue: catalogue,
      token: token
    } do
      item = F.item!(catalogue)

      conn =
        call(token, "ecommerce.set_availability", %{
          "items" => [%{"ref" => %{"id" => item.uuid}, "visibility" => "hidden"}]
        })

      assert conn.status == 422
      assert json(conn)["code"] == "validation_failed"
      assert F.reload!(item).data["ecommerce"]["shop_status"] == "active"
    end

    test "refuses a key without the write scope with 403", %{catalogue: catalogue, owner: owner} do
      item = F.item!(catalogue)
      token = read_only_token(owner, @prices)

      conn =
        call(token, "ecommerce.set_availability", %{
          "items" => [%{"ref" => %{"id" => item.uuid}, "visibility" => "archived"}]
        })

      assert conn.status == 403
      assert json(conn)["context"]["required_scope"] == @availability
      assert F.reload!(item).data["ecommerce"]["shop_status"] == "active"
    end
  end

  # -- ecommerce.attach_images ------------------------------------------------

  describe "ecommerce.attach_images" do
    test "a dry run checks the URLs and fetches nothing", %{catalogue: catalogue, token: token} do
      item = F.item!(catalogue)

      conn =
        call(token, "ecommerce.attach_images", %{
          "dry_run" => true,
          "items" => [
            %{
              "ref" => %{"id" => item.uuid},
              "images" => [%{"url" => "https://93.184.216.34/a.png"}]
            }
          ]
        })

      assert conn.status == 200

      assert %{
               "executed" => false,
               "dry_run" => true,
               "preview" => %{"rows" => [%{"action" => "update"}]}
             } =
               json(conn)

      assert F.reload!(item).data["media_order"] in [nil, []]
    end

    test "refuses a file URL with 422 and, with private networks allowed by the shop, a private address by row",
         %{catalogue: catalogue, token: token} do
      Settings.update_boolean_setting_with_module(
        "shop_image_import_allow_private_networks",
        true,
        "shop"
      )

      item = F.item!(catalogue)
      row = fn url -> %{"ref" => %{"id" => item.uuid}, "images" => [%{"url" => url}]} end

      file = call(token, "ecommerce.attach_images", %{"items" => [row.("file:///etc/passwd")]})
      assert file.status == 422
      assert json(file)["code"] == "validation_failed"

      private =
        call(token, "ecommerce.attach_images", %{
          "dry_run" => true,
          "items" => [row.("http://127.0.0.1/a.png")]
        })

      assert private.status == 200
      assert %{"preview" => %{"rows" => [%{"action" => "error"}]}} = json(private)
    end

    test "refuses a key without the write scope with 403", %{catalogue: catalogue, owner: owner} do
      item = F.item!(catalogue)
      token = read_only_token(owner, @read)

      conn =
        call(token, "ecommerce.attach_images", %{
          "items" => [
            %{
              "ref" => %{"id" => item.uuid},
              "images" => [%{"url" => "https://93.184.216.34/a.png"}]
            }
          ]
        })

      assert conn.status == 403
      assert json(conn)["context"]["required_scope"] == @images
    end
  end
end
