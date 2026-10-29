defmodule PhoenixKitEcommerce.OnlinePayment do
  @moduledoc """
  Hands a placed order whose payment option is online (Stripe, PayPal, ...)
  to billing for payment.

  Billing owns the invoice and the provider session; this module only asks
  `PhoenixKitBilling.start_order_payment/2` for a checkout URL and says
  whether an order is waiting for the money. The payment itself is confirmed
  by the provider's webhook through billing, never by the shopper returning
  to the shop.

  ## Older billing

  `start_order_payment/2` is looked up with `function_exported?/3`, so a
  host on a billing that lacks it keeps today's behaviour exactly: the order
  is placed and nothing is started (`supported?/0` is `false`, `awaiting?/1`
  is `false`, so no notification is held back either).

  The billing module is read from the `:online_payment_module` application
  env (default `PhoenixKitBilling`), the seam the tests use.
  """

  require Logger

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Web.Helpers

  @unpaid ~w(draft pending confirmed)

  @doc """
  The origin (`scheme://host[:port]`) of the request a LiveView socket is
  connected on, for `start/3`'s `:origin`; `nil` when it is not known or not
  trusted.

  On a connected mount the socket's `host_uri` comes from the `url` the client
  sends in the join, so it is only believed when its host is one the site
  serves: the endpoint's host, the host of `Routes.base_url/0` or the
  canonical host of the page's language. Anything else answers `nil`, and
  `start/3` then uses `Routes.base_url/0`, so a forged host cannot make the
  provider send the shopper (and the order link) to another site.
  """
  @spec origin(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def origin(%{host_uri: %URI{scheme: scheme, host: host, port: port}} = socket)
      when scheme in ["http", "https"] and is_binary(host) do
    if String.downcase(host) in trusted_hosts(socket) do
      "#{scheme}://#{host_for_url(host)}#{port_suffix(scheme, port)}"
    end
  end

  def origin(_socket), do: nil

  defp port_suffix("http", port) when port in [nil, 80], do: ""
  defp port_suffix("https", port) when port in [nil, 443], do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  # An IPv6 literal is a host without brackets in a URI struct and needs them
  # back in a URL.
  defp host_for_url(host), do: if(String.contains?(host, ":"), do: "[#{host}]", else: host)

  defp trusted_hosts(socket) do
    assigns = Map.get(socket, :assigns, %{})

    # The language the return URLs are built in (`Helpers.page_path/3`).
    languages =
      case assigns[:current_locale] do
        language when is_binary(language) -> [language]
        _ -> [Translations.default_language()]
      end

    canonical = Enum.map(languages, &Routes.canonical_host/1)

    [endpoint_host(socket), uri_host(Routes.base_url()) | Enum.map(canonical, &uri_host/1)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp endpoint_host(%{endpoint: endpoint}) when is_atom(endpoint) and not is_nil(endpoint) do
    if function_exported?(endpoint, :host, 0), do: endpoint.host()
  end

  defp endpoint_host(_socket), do: nil

  # `host`, `host:port` or a full URL, reduced to the host.
  defp uri_host(nil), do: nil

  defp uri_host(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) -> host
      _ -> value |> String.split(":") |> List.first()
    end
  end

  @doc "Whether the installed billing can start an order's payment."
  @spec supported?() :: boolean()
  def supported? do
    module = billing_module()
    Code.ensure_loaded?(module) and function_exported?(module, :start_order_payment, 2)
  end

  @doc "Whether the order was placed with an online payment option."
  @spec online?(map()) :: boolean()
  def online?(%{payment_option_uuid: uuid}) when is_binary(uuid) do
    match?(%{type: "online"}, Billing.get_payment_option(uuid))
  rescue
    _ -> false
  end

  def online?(_order), do: false

  @doc "Whether the order is an online order that has not been paid yet."
  @spec awaiting?(map()) :: boolean()
  def awaiting?(%{status: status} = order) when status in @unpaid,
    do: payable_total?(order) and supported?() and online?(order)

  def awaiting?(_order), do: false

  # A free order (a full discount) has nothing to pay: a provider refuses a
  # zero session, which would strand the order on "Awaiting payment".
  defp payable_total?(%{total: %Decimal{} = total}), do: Decimal.compare(total, 0) == :gt
  defp payable_total?(_order), do: true

  @doc """
  Starts the payment of `order` and returns where to send the shopper.

  `assigns` is the page's (it carries the locale the return URLs are built
  in); `origin:` is the scheme and host the shopper is on, so the provider
  sends them back to the host that holds their shop session cookie (the
  configured site URL when omitted). Returns `{:ok, url}`, `:paid` when billing says the order is already
  paid, or `{:error, reason}` with an atom `Errors.message/1` knows:
  `:payment_unavailable` (the provider is not configured) or
  `:payment_start_failed`.
  """
  @spec start(map(), map(), keyword()) :: {:ok, String.t()} | :paid | {:error, atom()}
  def start(order, assigns, opts \\ []) do
    origin = opts[:origin] || Routes.base_url()

    opts =
      [
        success_url: return_url(origin, assigns, order, "success"),
        cancel_url: return_url(origin, assigns, order, "cancelled")
      ] ++ email_opt(order)

    case billing_module().start_order_payment(order, opts) do
      {:ok, %{url: url}} when is_binary(url) ->
        {:ok, url}

      {:error, :already_paid} ->
        :paid

      {:error, reason} when reason in [:provider_not_available, :not_configured] ->
        {:error, :payment_unavailable}

      {:error, reason} ->
        failed(order, reason)

      other ->
        failed(order, other)
    end
  rescue
    error -> failed(order, error)
  end

  defp failed(order, reason) do
    Logger.warning(
      "[Shop] could not start the online payment of order #{order.order_number}: " <>
        inspect(reason)
    )

    {:error, :payment_start_failed}
  end

  # The shopper returns to the order page either way; the page decides what
  # to say from the order, so `payment=` is only a hint for the first render.
  defp return_url(origin, assigns, order, outcome) do
    origin <>
      Helpers.page_path(assigns, "/checkout/complete/#{order.uuid}", payment: outcome)
  end

  defp email_opt(%{billing_snapshot: %{"email" => email}}) when is_binary(email) and email != "",
    do: [customer_email: email]

  defp email_opt(_order), do: []

  defp billing_module,
    do: Application.get_env(:phoenix_kit_ecommerce, :online_payment_module, PhoenixKitBilling)
end
