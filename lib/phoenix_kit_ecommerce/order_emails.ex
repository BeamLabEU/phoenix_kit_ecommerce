defmodule PhoenixKitEcommerce.OrderEmails do
  @moduledoc """
  The emails a shop order sends: the buyer's confirmation, the buyer's paid
  email, and the detailed email to the shop's own addresses.

  ## When

  | Moment | Buyer | Shop |
  |---|---|---|
  | placed, not awaiting online payment | `shop_order_confirmation` | `shop_order_received` |
  | placed, awaiting online payment | nothing | nothing |
  | paid | `shop_order_paid` | `shop_order_received`, unless already sent |

  An online order is not confirmed until the money lands, the same rule
  `PhoenixKitEcommerce.Notifications.order_placed/2` follows: both sides hear
  when it is paid.

  ## Delivery

  Each email is one `Workers.OrderEmailWorker` job. The order's are queued in the
  transaction that creates it and the paid ones by billing's durable order event
  (`PhoenixKitEcommerce.OrderEmailHandler`), so no mail server is ever waited for
  at the checkout and a failure retries on its own.

  Once per order: a job is unique per order and email, and a sent email is marked
  in `metadata["_shop_emails"]`, which outlives the job row and changes neither
  the order's revision nor `updated_at`. The mark is written after the send, so
  a crash between the two can repeat an email; it cannot lose one.

  ## Who

  The buyer is the address on the order, in the language of the checkout
  (`metadata["checkout_language"]`), and `buyer_emails_enabled?/0` can turn these
  off. The link to the order is the account page for a confirmed buyer. A guest
  has no account, and under the default `:strict` lookup policy the order page
  opens only in the session that placed the order, so a guest's email carries the
  link only under `:link`.

  The shop's addresses are `shop_recipients/0`, in the site's primary language;
  with none, nothing is sent. Per-user notification preferences play no part.
  """

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.RepoHelper, only: [repo: 0]

  require Logger

  alias PhoenixKit.Mailer
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Notifications
  alias PhoenixKitEcommerce.OnlinePayment
  alias PhoenixKitEcommerce.OrderEmailDefaults
  alias PhoenixKitEcommerce.Policy
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Workers.OrderEmailWorker

  @emails %{
    "buyer_placed" => "shop_order_confirmation",
    "buyer_paid" => "shop_order_paid",
    "shop" => "shop_order_received"
  }

  @sent_key "_shop_emails"
  @buyer_setting "shop_order_emails_to_buyer"
  @recipients_setting "shop_order_email_recipients"
  @address ~r/\A[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+\z/

  @doc """
  Queues the emails of an order just placed. Call it in the transaction that
  creates the order, so the jobs commit with it. An Oban that is not running is
  logged and never fails the checkout.
  """
  @spec order_placed(map()) :: :ok
  def order_placed(order) do
    if OnlinePayment.awaiting?(order), do: :ok, else: enqueue(order, ~w(buyer_placed shop))
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.error(
        "[Shop] emails of order #{order.order_number} not queued: #{Exception.message(error)}"
      )

      :ok
  end

  @doc "Queues the emails of an order that became paid."
  @spec order_paid(map()) :: :ok
  def order_paid(order), do: enqueue(order, ~w(buyer_paid shop))

  defp enqueue(order, emails) do
    Enum.each(emails, fn email ->
      %{"order_uuid" => order.uuid, "email" => email}
      |> OrderEmailWorker.new()
      |> Oban.insert!()
    end)
  end

  @doc """
  Sends one email of `order` (`"buyer_placed"`, `"buyer_paid"` or `"shop"`), unless
  it was sent already or has nobody to go to. Returns `{:error, reason}` for the
  job to retry; an email that went is marked.
  """
  @spec deliver(String.t(), map()) :: :ok | {:error, term()}
  def deliver(email, order) when is_map_key(@emails, email) do
    if sent?(order, email), do: :ok, else: send_email(email, order)
  end

  defp sent?(order, email), do: get_in(order.metadata, [@sent_key, email]) == true

  defp send_email("shop", order) do
    case shop_recipients() do
      [] -> :ok
      recipients -> send_to_shop(order, recipients)
    end
  end

  defp send_email(email, order) do
    case buyer_emails_enabled?() && buyer_address(order) do
      address when is_binary(address) -> send_to_buyer(email, order, address)
      _off_or_nobody -> :ok
    end
  end

  defp send_to_buyer(email, order, address) do
    language = Notifications.buyer_language(order.metadata["checkout_language"])

    deliver_template(email, order, address, language, order_url(order, language),
      user_uuid: order.user_uuid
    )
  end

  defp send_to_shop(order, recipients) do
    language = Translations.default_language()
    reply_to = get_in(order.billing_snapshot || %{}, ["email"])

    deliver_template("shop", order, recipients, language, nil,
      reply_to: if(is_binary(reply_to) and reply_to != "", do: reply_to)
    )
  end

  defp deliver_template(email, order, to, language, order_url, opts) do
    template = Map.fetch!(@emails, email)
    locale = base_locale(language)

    variables =
      Gettext.with_locale(PhoenixKitEcommerce.Gettext, locale, fn ->
        OrderEmailDefaults.variables(order, order_url)
      end)

    defaults = OrderEmailDefaults.defaults_for(template, variables)

    result =
      Mailer.send_from_template(
        template,
        to,
        variables,
        [
          locale: language,
          defaults: fn -> Gettext.with_locale(PhoenixKitEcommerce.Gettext, locale, defaults) end,
          layout: OrderEmailDefaults.layout_group(),
          metadata: %{order_uuid: order.uuid}
        ] ++ opts
      )

    case result do
      {:ok, _delivered} -> mark_sent(order.uuid, email)
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_locale(language),
    do: language |> String.split(["-", "_"]) |> hd() |> String.downcase()

  defp mark_sent(order_uuid, email) do
    {:ok, _count} =
      repo().transaction(fn ->
        order =
          repo().one!(from(o in Billing.Order, where: o.uuid == ^order_uuid, lock: "FOR UPDATE"))

        sent = Map.put(order.metadata[@sent_key] || %{}, email, true)

        repo().update_all(from(o in Billing.Order, where: o.uuid == ^order_uuid),
          set: [metadata: Map.put(order.metadata, @sent_key, sent)]
        )
      end)

    :ok
  end

  defp buyer_address(order) do
    case order.billing_snapshot do
      %{"email" => email} when is_binary(email) and email != "" -> email
      _no_email -> account_email(order)
    end
  end

  defp account_email(%{user_uuid: uuid}) when is_binary(uuid) do
    case Auth.get_user(uuid) do
      %{email: email} -> email
      nil -> nil
    end
  end

  defp account_email(_order), do: nil

  defp order_url(order, language) do
    cond do
      confirmed_account?(order) ->
        absolute("/dashboard/orders/#{order.uuid}", language)

      Policy.order_lookup_policy() == :link ->
        absolute("/checkout/complete/#{order.uuid}", language)

      true ->
        nil
    end
  end

  defp confirmed_account?(%{user_uuid: uuid}) when is_binary(uuid),
    do: match?(%{confirmed_at: %DateTime{}}, Auth.get_user(uuid))

  defp confirmed_account?(_order), do: false

  defp absolute(path, language) do
    built = Routes.path(path, locale: Shop.url_locale(language))
    Routes.canonical_absolute_or_nil(built, language) || Routes.base_url() <> built
  end

  # -- settings ---------------------------------------------------------------

  @doc "Whether buyers get the order emails. On by default; a read error counts as off."
  @spec buyer_emails_enabled?() :: boolean()
  def buyer_emails_enabled? do
    Settings.get_setting_cached(@buyer_setting, "true") == "true"
  rescue
    _ -> false
  end

  @doc "Turns the buyer's order emails on or off."
  @spec set_buyer_emails_enabled(boolean()) :: {:ok, boolean()} | {:error, :update_failed}
  def set_buyer_emails_enabled(enabled) when is_boolean(enabled) do
    case Settings.update_boolean_setting_with_module(@buyer_setting, enabled, "shop") do
      {:ok, _} -> {:ok, enabled}
      _error -> {:error, :update_failed}
    end
  end

  @doc """
  The addresses that get the shop's order email. A stored value that is not an
  address is left out, and a read error counts as none.
  """
  @spec shop_recipients() :: [String.t()]
  def shop_recipients do
    @recipients_setting
    |> Settings.get_setting_cached("")
    |> split_addresses()
    |> Enum.filter(&Regex.match?(@address, &1))
  rescue
    _ -> []
  end

  @doc """
  Stores the shop's addresses from what a person typed: separated by commas,
  semicolons, spaces or new lines. Nothing is stored if one of them is not an
  address.
  """
  @spec set_shop_recipients(String.t()) ::
          {:ok, [String.t()]}
          | {:error, {:invalid_order_email_addresses, [String.t()]} | :update_failed}
  def set_shop_recipients(text) when is_binary(text) do
    addresses = text |> split_addresses() |> Enum.uniq()

    case Enum.reject(addresses, &Regex.match?(@address, &1)) do
      [] -> store_recipients(addresses)
      invalid -> {:error, {:invalid_order_email_addresses, invalid}}
    end
  end

  defp store_recipients(addresses) do
    value = Enum.join(addresses, ", ")

    case Settings.update_setting_with_module(@recipients_setting, value, "shop") do
      {:ok, _} -> {:ok, addresses}
      _error -> {:error, :update_failed}
    end
  end

  defp split_addresses(text) when is_binary(text),
    do: String.split(text, [",", ";", " ", "\n", "\r", "\t"], trim: true)

  defp split_addresses(_other), do: []
end
