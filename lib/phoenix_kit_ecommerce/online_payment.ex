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
  The origin (`scheme://host[:port]`) for `start/3`'s `:origin`, from the request
  a LiveView socket is connected on; `nil` when it is not known or not trusted.

  On a connected mount the socket's `host_uri` comes from the `url` the client
  sends in the join, so the client's host is only used to PICK one of the
  origins the site itself serves: the endpoint's URL, `Routes.base_url/0`, or
  the canonical host of the page's language (on the scheme of the site base).
  What is returned is that origin as the site writes it, never the client's
  spelling of scheme, case or port. Any other host answers `nil`, and `start/3`
  then uses `Routes.base_url/0`, so a forged host cannot make the provider send
  the shopper (and the order link) to another site.
  """
  @spec origin(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def origin(%{host_uri: %URI{host: host}} = socket) when is_binary(host) do
    wanted = String.downcase(host)

    Enum.find_value(trusted_origins(socket), fn {trusted_host, origin} ->
      if trusted_host == wanted, do: origin
    end)
  end

  def origin(_socket), do: nil

  # `{host, origin}` of every origin the site serves.
  defp trusted_origins(socket) do
    assigns = Map.get(socket, :assigns, %{})
    base = Routes.base_url()
    scheme = base |> URI.parse() |> Map.get(:scheme) |> Kernel.||("https")

    # The language the return URLs are built in (`Helpers.page_path/3`).
    languages =
      case assigns[:current_locale] do
        language when is_binary(language) -> [language]
        _ -> [Translations.default_language()]
      end

    canonical =
      for language <- languages,
          host_port = Routes.canonical_host(language),
          is_binary(host_port),
          do: scheme <> "://" <> host_port

    for url <- [endpoint_url(socket), base | canonical],
        is_binary(url),
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
          [URI.parse(url)] do
      {String.downcase(host), String.trim_trailing(url, "/")}
    end
  end

  defp endpoint_url(%{endpoint: endpoint}) when is_atom(endpoint) and not is_nil(endpoint) do
    if function_exported?(endpoint, :url, 0), do: endpoint.url()
  end

  defp endpoint_url(_socket), do: nil

  @doc "Whether the installed billing can start an order's payment."
  @spec supported?() :: boolean()
  def supported? do
    module = billing_module()
    Code.ensure_loaded?(module) and function_exported?(module, :start_order_payment, 2)
  end

  @doc """
  Whether the order was placed with an online payment option. Uses its
  checkout snapshot; older orders fall back to the live payment option.
  """
  @spec online?(map()) :: boolean()
  def online?(%{metadata: %{"payment_option_type" => type}}) when type in ~w(online offline),
    do: type == "online"

  def online?(%{payment_option_uuid: uuid}) when is_binary(uuid) do
    match?(%{type: "online"}, Billing.get_payment_option(uuid))
  rescue
    _ -> false
  end

  def online?(_order), do: false

  @doc "Whether this checkout requires a supported online payment, regardless of its status."
  @spec required?(map()) :: boolean()
  def required?(order), do: payable_total?(order) and supported?() and online?(order)

  @doc "Whether the order is an online order that has not been paid yet."
  @spec awaiting?(map()) :: boolean()
  def awaiting?(%{status: status} = order) when status in @unpaid, do: required?(order)

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
