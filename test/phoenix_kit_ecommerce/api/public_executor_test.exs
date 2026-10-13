defmodule PhoenixKitEcommerce.API.PublicExecutorTest do
  @moduledoc """
  The five tools through core's real executor: schema validation, `max_items`,
  rate limiting, problem+json and the JSON answer. `Auth` (the API switch and
  the website gate) sits in front of the executor in production and is core's
  own test; here the executor is called directly with an anonymous caller.

  `async: false`: Billing's currency cache and the limiter table are node-global.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :requires_core_api

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKit.API.Executor
  alias PhoenixKit.Settings

  setup do
    disable_languages!()
    currencies!()
    sample_shop!()
  end

  # Fixed one-minute windows: start with room, or the counter can reset between two calls.
  defp wait_for_window_room(min_left_ms \\ 1_500) do
    left = 60_000 - rem(System.os_time(:millisecond), 60_000)
    if left < min_left_ms, do: Process.sleep(left + 10)
    :ok
  end

  defp call(tool, input, ip \\ nil) do
    ip = ip || {10, 1, rem(System.unique_integer([:positive]), 250), :rand.uniform(250)}

    conn =
      :post
      |> Plug.Test.conn("/api/shop/v1/" <> tool)
      |> Map.put(:remote_ip, ip)
      |> Executor.call(:public, tool, input)

    {conn.status, JSON.decode!(conn.resp_body), conn}
  end

  test "shop.search_products answers 200 with JSON", t do
    {status, body, conn} = call("shop.search_products", %{"q" => "vase"})

    assert status == 200
    assert body["count"] == 3

    assert body["items"] |> Enum.take(2) |> Enum.map(& &1["id"]) |> Enum.sort() ==
             Enum.sort([t.a, t.c])

    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end

  test "language and currency are accepted; any other field is a 422, the control fields of write tools included" do
    assert {200, %{"currency" => "EUR"}, _} =
             call("shop.search_products", %{
               "q" => "vase",
               "language" => "en",
               "currency" => "EUR"
             })

    for bad <- [
          %{"bogus" => 1},
          %{"dry_run" => true},
          %{"confirm_token" => "x"},
          %{"api_key" => "x"}
        ] do
      assert {422, body, _} = call("shop.search_products", bad)
      assert body["code"] == "validation_failed"
      assert [%{"path" => path}] = body["context"]["errors"]
      assert path == bad |> Map.keys() |> hd()
    end
  end

  test "an unknown language or currency is a 422 that lists what is allowed" do
    assert {422, body, _} = call("shop.search_products", %{"language" => "xx"})
    assert [%{"path" => "language", "allowed" => ["en"]}] = body["context"]["errors"]

    assert {422, body, _} = call("shop.search_products", %{"currency" => "XXX"})
    assert [%{"path" => "currency", "allowed" => ["EUR", "USD"]}] = body["context"]["errors"]
  end

  test "schema errors name the field: a limit of 0, a field that is not an item field" do
    assert {422, body, _} = call("shop.search_products", %{"limit" => 0})
    assert [%{"path" => "limit"}] = body["context"]["errors"]

    assert {422, body, _} = call("shop.search_products", %{"fields" => ["cost_per_item"]})
    assert [%{"path" => "fields[0]"}] = body["context"]["errors"]
  end

  test "the executor enforces the batch caps before any handler runs" do
    assert {422, body, _} =
             call("shop.search_products_batch", %{"queries" => List.duplicate(%{}, 21)})

    assert [%{"path" => "queries"}] = body["context"]["errors"]

    ids = List.duplicate(Ecto.UUID.generate(), 51)
    assert {422, body, _} = call("shop.get_products", %{"ids" => ids})
    assert [%{"path" => "ids"}] = body["context"]["errors"]

    assert {422, _, _} = call("shop.search_products_batch", %{"queries" => []})
  end

  test "the tool's own item cap answers before the schema looks at the items" do
    # 21 queries that are each invalid: the cap is one error on the list, not 21 item errors.
    bad = List.duplicate(%{"bogus" => 1}, 21)

    assert {422, body, _} = call("shop.search_products_batch", %{"queries" => bad})
    assert [%{"path" => "queries", "limit" => 20}] = body["context"]["errors"]

    bad_ids = List.duplicate(1, 51)
    assert {422, body, _} = call("shop.get_products", %{"ids" => bad_ids})
    assert [%{"path" => "ids", "limit" => 50}] = body["context"]["errors"]
  end

  test "a schema-level problem in one batch query fails the whole call and names the query" do
    assert {422, body, _} =
             call("shop.search_products_batch", %{
               "queries" => [%{"q" => "vase"}, %{"limit" => 0}]
             })

    assert [%{"path" => "queries[1].limit"}] = body["context"]["errors"]
  end

  test "get_products hides what is hidden: a draft and an unknown id answer alike" do
    draft = legacy_product!(%{"en" => "Draft Lamp"}, %{status: "draft"})

    {200, body, _} =
      call("shop.get_products", %{"ids" => [draft.uuid, Ecto.UUID.generate()]})

    assert [%{"error" => first}, %{"error" => second}] = body["results"]
    assert first == second
    assert body["summary"] == %{"found" => 0, "discontinued" => 0, "not_found" => 2}
  end

  test "list_categories and similar_products answer through the executor", t do
    assert {200, %{"categories" => [%{"name" => "Home", "total_count" => 3}]}, _} =
             call("shop.list_categories", %{})

    assert {200, %{"items" => items}, _} = call("shop.similar_products", %{"id" => t.a})
    assert Enum.map(items, & &1["id"]) == [t.c, t.d]

    assert {404, %{"code" => "not_found"}, _} =
             call("shop.similar_products", %{"id" => Ecto.UUID.generate()})
  end

  test "an unknown tool is 404 not_found; with the shop module disabled it is 404 module_disabled" do
    assert {404, %{"code" => "not_found"}, _} = call("shop.no_such_tool", %{})

    {:ok, _} = Settings.update_setting("shop_enabled", "false")
    assert {404, %{"code" => "module_disabled"}, _} = call("shop.search_products", %{})
  end

  test "a batch of 20 queries costs 20 units: the second batch from one address is refused" do
    wait_for_window_room()
    {:ok, _} = Settings.update_setting("api_public_ip_rate_per_min", "25")
    ip = {10, 9, 9, 9}
    twenty = %{"queries" => List.duplicate(%{"q" => "vase"}, 20)}

    assert {200, %{"count" => 20}, _} = call("shop.search_products_batch", twenty, ip)

    assert {429, %{"code" => "rate_limited"}, _} = call("shop.search_products_batch", twenty, ip)
  end

  test "GET discovery lists the five tools with their schemas" do
    conn =
      :get
      |> Plug.Test.conn("/api/shop/v1/")
      |> Map.put(:remote_ip, {10, 1, 2, 3})
      |> Executor.list(:public)

    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)
    names = body["tools"] |> Enum.map(& &1["name"])

    assert Enum.filter(names, &String.starts_with?(&1, "shop.")) |> Enum.sort() ==
             ~w(shop.get_products shop.list_categories shop.search_products shop.search_products_batch shop.similar_products)

    search = Enum.find(body["tools"], &(&1["name"] == "shop.search_products"))
    assert search["input_schema"]["additionalProperties"] == false
    assert search["annotations"]["read_only"] == true
  end
end
