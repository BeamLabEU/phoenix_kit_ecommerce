defmodule PhoenixKitEcommerce.Web.ShipmentLabelsController do
  @moduledoc """
  The labels of shipments as one document from their carrier:
  `GET {prefix}/shop-shipments/labels?ids=<uuid>,<uuid>...`, answered as a
  download (`PhoenixKitEcommerce.Shipments.print_labels/2`).

  The route sits outside the admin segment (see `Web.Routes.generate/1`), so
  core's admin live_session does not guard it: the `:phoenix_kit_admin_only`
  pipeline admits an admin, and this controller checks `shop.manage_shipments`
  itself, on the scope the pipeline assigned. At most 50 ids, each a UUID,
  all of one carrier connection; the paper size is the shop's
  `shipping_label_format/0`. A refusal goes back to the Shipments page with
  the reason. Each print is logged in Activity, with no recipient data.
  """

  use PhoenixKitEcommerce.Web, :controller

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{Activity, Errors, Shipments}
  alias PhoenixKitEcommerce.Web.Authz

  @doc "GET: the labels of `ids`, as an attachment."
  def index(conn, _params) do
    cond do
      not Shop.enabled?() ->
        conn
        |> put_flash(:error, gettext("The shop is switched off."))
        |> redirect(to: Routes.path("/admin"))

      not Authz.can?(conn, :manage_shipments) ->
        conn
        |> put_flash(:error, gettext("You don't have permission to do that"))
        |> redirect(to: Routes.path("/admin/shop"))

      true ->
        # Read from the query string itself: the ids are never a path
        # segment, and a host's endpoint may parse no query into `params`.
        conn = fetch_query_params(conn)
        print(conn, label_ids(conn.query_params))
    end
  end

  defp print(conn, ids) do
    format = Shop.shipping_label_format()

    case Shipments.print_labels(ids, format: format) do
      {:ok, %{content_type: content_type, body: body, shipments: shipments}} ->
        log_print(conn, shipments, format)

        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_download({:binary, body},
          filename: "shipment-labels-#{Date.utc_today()}.#{extension(content_type)}",
          content_type: content_type,
          disposition: :attachment
        )

      {:error, reason} ->
        conn
        |> put_flash(:error, Errors.message(reason))
        |> redirect(to: Routes.path("/admin/shop/shipments"))
    end
  end

  # `ids` is a comma-separated list; a repeated `ids[]` parameter is taken too.
  defp label_ids(%{"ids" => ids}) when is_binary(ids),
    do: ids |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp label_ids(%{"ids" => ids}) when is_list(ids), do: Enum.filter(ids, &is_binary/1)
  defp label_ids(_params), do: []

  defp extension(content_type) do
    case MIME.extensions(content_type) do
      [extension | _] -> extension
      [] -> "pdf"
    end
  end

  defp log_print(conn, [first | _] = shipments, format) do
    Activity.log("shop.shipment_labels_printed",
      actor_uuid: Activity.actor_uuid(conn),
      actor_role: Activity.actor_role(conn),
      resource_type: "shipment",
      resource_uuid: first.uuid,
      metadata: %{
        "provider" => first.provider,
        "format" => Atom.to_string(format),
        "count" => length(shipments),
        "shipment_uuids" => Enum.map(shipments, & &1.uuid)
      }
    )
  end
end
