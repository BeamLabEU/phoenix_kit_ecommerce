defmodule PhoenixKitEcommerce.OrderEmailDefaults do
  @moduledoc """
  The content the shop's order emails fall back to, the order as their
  variables, and their entries in core's email preview.

  Handed to `PhoenixKit.Mailer.send_from_template/4` as `:defaults`, so a host
  overrides any part the usual way: an active database template or a file under
  `priv/phoenix_kit_templates/<name>/`. Core wraps them in its layout in the
  `"shop"` group (`_layout-shop`, `_header-shop`, `_footer-shop`).

  The HTML carries the order as a ready-made table (`{{{order_table_html}}}`),
  every value escaped and styled inline; the plain text uses `{{order_text}}`.

  What an order line says here is what the order page says: a price-on-request
  line is never a 0.00, a pay-on-delivery shipping line is never free. Order
  lines keep the text the buyer saw, in the language they bought in, so the
  shop's email shows them in that language around its own copy.

  These are functions rather than a map because they are evaluated in the
  locale of the recipient, not of the job that sends them.
  """

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Paths, as: BillingPaths
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.NamePrefix
  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Web.Helpers
  alias PhoenixKitEcommerce.Web.StatusLabels

  @confirmation "shop_order_confirmation"
  @paid "shop_order_paid"
  @received "shop_order_received"
  @templates [@confirmation, @paid, @received]

  @layout_group "shop"

  @font "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
  @muted "color:#71717a;font-size:13px;"
  @cell_style "padding:10px 0;border-bottom:1px solid #e4e4e7;vertical-align:top;" <>
                "font-family:#{@font};font-size:14px;line-height:1.4;color:#18181b;"

  @doc "The template names this module supplies defaults for."
  @spec template_names() :: [String.t()]
  def template_names, do: @templates

  @doc "The layout group the emails are sent in."
  @spec layout_group() :: String.t()
  def layout_group, do: @layout_group

  @doc """
  A zero-arity function returning the default content of `name`. With
  `variables`, both bodies leave out what the send has nothing for, rather than
  show an empty label.
  """
  @spec defaults_for(String.t(), map() | :all) ::
          (-> %{subject: String.t(), markdown: String.t(), text: String.t()})
  def defaults_for(name, variables \\ :all) when name in @templates do
    present = present(variables)

    fn ->
      %{subject: subject(name), markdown: markdown(name, present), text: text(name, present)}
    end
  end

  defp present(:all), do: :all

  defp present(variables) do
    for {key, value} <- variables,
        is_binary(value),
        String.trim(value) != "",
        into: MapSet.new() do
      key
    end
  end

  defp has?(:all, _variable), do: true
  defp has?(present, variable), do: MapSet.member?(present, variable)

  # -- copy -------------------------------------------------------------------

  defp subject(@confirmation), do: gettext("Your order {{order_number}}")
  defp subject(@paid), do: gettext("Payment received for order {{order_number}}")
  defp subject(@received), do: gettext("New order {{order_number}}")

  defp heading(@confirmation), do: gettext("Thank you for your order")
  defp heading(@paid), do: gettext("Your payment has arrived")
  defp heading(@received), do: gettext("New order {{order_number}}")

  defp intro(@confirmation), do: gettext("We have received your order {{order_number}}.")
  defp intro(@paid), do: gettext("Your order {{order_number}} is paid and confirmed.")
  defp intro(@received), do: gettext("Status: {{order_status}}")

  defp markdown(name, present) do
    join([
      "## " <> heading(name),
      hello(name, present),
      intro(name),
      "{{{order_table_html}}}",
      has?(present, "order_notes") && "{{order_notes}}",
      has?(present, "delivery") && gettext("**Delivery:** {{delivery}}"),
      customer(name, present),
      link_markdown(name, present)
    ])
  end

  defp text(name, present) do
    join([
      heading(name),
      hello(name, present),
      intro(name),
      "{{order_text}}",
      has?(present, "order_notes") && "{{order_notes}}",
      has?(present, "delivery") && gettext("Delivery: {{delivery}}"),
      customer_text(name, present),
      link_text(name, present)
    ])
  end

  defp hello(@received, _present), do: nil

  defp hello(_name, present),
    do: has?(present, "customer_name") && gettext("Hello {{customer_name}},")

  defp customer(@received, present) do
    join_lines("  \n", [
      has?(present, "customer_name") && gettext("**Customer:** {{customer_name}}"),
      has?(present, "customer_email") && gettext("**Email:** {{customer_email}}"),
      has?(present, "customer_phone") && gettext("**Phone:** {{customer_phone}}"),
      has?(present, "billing_address") && gettext("**Address:** {{billing_address}}")
    ])
  end

  defp customer(_name, _present), do: nil

  defp customer_text(@received, present) do
    join_lines("\n", [
      has?(present, "customer_name") && gettext("Customer: {{customer_name}}"),
      has?(present, "customer_email") && gettext("Email: {{customer_email}}"),
      has?(present, "customer_phone") && gettext("Phone: {{customer_phone}}"),
      has?(present, "billing_address") && gettext("Address: {{billing_address}}")
    ])
  end

  defp customer_text(_name, _present), do: nil

  defp link_markdown(@received, present),
    do: has?(present, "admin_order_url") && gettext("[Open the order]({{admin_order_url}})")

  defp link_markdown(_name, present),
    do: has?(present, "order_url") && gettext("[View your order]({{order_url}})")

  defp link_text(@received, present),
    do: has?(present, "admin_order_url") && gettext("Open the order: {{admin_order_url}}")

  defp link_text(_name, present),
    do: has?(present, "order_url") && gettext("View your order: {{order_url}}")

  defp join(parts), do: parts |> Enum.filter(&filled?/1) |> Enum.join("\n\n")

  # In Markdown a line break takes two trailing spaces, or the lines run together.
  defp join_lines(separator, parts) do
    case Enum.filter(parts, &filled?/1) do
      [] -> nil
      lines -> Enum.join(lines, separator)
    end
  end

  defp filled?(part), do: is_binary(part) and part != ""

  # -- variables --------------------------------------------------------------

  @doc """
  The variables of `order`'s emails, in the current locale. `order_url` is passed
  in, because who may open which page is decided by who the email goes to.
  """
  @spec variables(map(), String.t() | nil) :: %{String.t() => String.t()}
  def variables(order, order_url) do
    currency = Shop.currency_for_code(order.currency)
    rows = line_rows(order, currency) ++ total_rows(order, currency)
    snapshot = order.billing_snapshot || %{}

    %{
      "order_number" => order.order_number,
      "order_status" => StatusLabels.order(order.status),
      "order_table_html" => table_html(rows),
      "order_text" => table_text(rows),
      "order_notes" => notes(order),
      "delivery" => delivery(order),
      "order_url" => order_url || "",
      "admin_order_url" => Routes.base_url() <> BillingPaths.order_detail(order.uuid),
      "customer_name" => name(snapshot),
      "customer_email" => snapshot["email"] || "",
      "customer_phone" => snapshot["phone"] || "",
      "billing_address" => address(snapshot)
    }
  end

  defp line_rows(order, currency) do
    Enum.map(order.line_items || [], fn line ->
      %{
        name: line_name(line),
        detail: line_detail(line),
        amount: line_amount(line, currency),
        strong: false
      }
    end)
  end

  defp line_name(%{"type" => "shipping"} = line), do: line["name"] || ""

  defp line_name(line) do
    "#{NamePrefix.strip(line["name"] || "")} × #{line["quantity"]}"
  end

  defp line_detail(%{"type" => "shipping"} = line), do: PriceDisplay.line_description(line)

  defp line_detail(line) do
    Enum.map_join(line["selected_specs"] || %{}, ", ", fn {key, value} ->
      "#{Options.humanize_key(key)}: #{value}"
    end)
  end

  defp line_amount(line, currency) do
    if PriceDisplay.line_pay_on_delivery?(line) do
      gettext("Paid on delivery")
    else
      PriceDisplay.render(nil, currency, :order,
        amount: line["total"],
        on_request: PriceDisplay.line_on_request?(line)
      )
    end
  end

  defp total_rows(order, currency) do
    [
      row(gettext("Subtotal"), order.subtotal, currency),
      positive?(order.tax_amount) && row(gettext("Tax"), order.tax_amount, currency),
      positive?(order.discount_amount) &&
        %{row(gettext("Discount"), order.discount_amount, currency) | amount: discount(order)},
      %{row(gettext("Total"), order.total, currency) | strong: true}
    ]
    |> Enum.filter(& &1)
  end

  defp discount(order),
    do: "-" <> Helpers.format_price(order.discount_amount, order.currency)

  defp row(label, amount, currency) do
    %{name: label, detail: "", amount: Helpers.format_price(amount, currency), strong: false}
  end

  defp positive?(%Decimal{} = amount), do: Decimal.compare(amount, 0) == :gt
  defp positive?(_amount), do: false

  defp table_html(rows) do
    ~s(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" ) <>
      ~s(style="width:100%;border-collapse:collapse;margin:0 0 16px;">) <>
      Enum.map_join(rows, "", &row_html/1) <> "</table>"
  end

  defp row_html(row) do
    name = if row.strong, do: "<strong>#{escape(row.name)}</strong>", else: escape(row.name)
    amount = if row.strong, do: "<strong>#{escape(row.amount)}</strong>", else: escape(row.amount)

    detail =
      case row.detail do
        "" -> ""
        text -> ~s(<div style="#{@muted}">#{escape(text)}</div>)
      end

    ~s(<tr><td style="#{@cell_style}">#{name}#{detail}</td>) <>
      ~s(<td align="right" style="#{@cell_style}padding-left:16px;text-align:right;) <>
      ~s(white-space:nowrap;">#{amount}</td></tr>)
  end

  defp escape(value),
    do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp table_text(rows) do
    Enum.map_join(rows, "\n", fn row ->
      detail = if row.detail == "", do: "", else: " (#{row.detail})"
      "#{row.name}#{detail}: #{row.amount}"
    end)
  end

  defp notes(order) do
    [
      PriceDisplay.any_line_on_request?(order.line_items) &&
        gettext("Items priced on request are not included in this total."),
      PriceDisplay.order_shipping_pay_on_delivery?(order) &&
        gettext(
          "Shipping is not included in this total: you pay the carrier at their rates on delivery."
        )
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  # A pickup point's label says where the parcel goes; otherwise it goes to the
  # billing address, the only address an order has.
  defp delivery(order) do
    case Enum.find(order.line_items || [], &(&1["type"] == "shipping")) do
      nil ->
        if order.metadata["shipping_skipped"],
          do: address(order.billing_snapshot || %{}),
          else: ""

      line ->
        [line["name"], line["destination_label"] || address(order.billing_snapshot || %{})]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" — ")
    end
  end

  defp name(snapshot) do
    [snapshot["first_name"], snapshot["last_name"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp address(snapshot) do
    [
      snapshot["address_line1"],
      snapshot["address_line2"],
      snapshot["postal_code"],
      snapshot["city"],
      snapshot["country"]
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  # -- preview ----------------------------------------------------------------

  @doc "The entries of `c:PhoenixKit.Module.email_templates/0`."
  @spec catalog_entries() :: [map()]
  def catalog_entries do
    [
      entry(
        @confirmation,
        gettext("Order confirmation"),
        gettext("Sent to the buyer when an order is placed, unless it awaits online payment.")
      ),
      entry(
        @paid,
        gettext("Order paid"),
        gettext("Sent to the buyer when an order becomes paid.")
      ),
      entry(
        @received,
        gettext("New order for the shop"),
        gettext(
          "Sent to the shop's order email addresses when an order is placed, or paid if it waited for online payment."
        )
      )
    ]
  end

  defp entry(name, label, description) do
    %{
      name: name,
      label: label,
      description: description,
      defaults: fn ->
        Gettext.with_locale(
          PhoenixKitEcommerce.Gettext,
          Gettext.get_locale(PhoenixKitWeb.Gettext),
          defaults_for(name)
        )
      end,
      variables: &sample_variables/0,
      layout: @layout_group
    }
  end

  defp sample_variables do
    rows = [
      %{name: "Ceramic vase × 2", detail: "Color: Red", amount: "€40.00", strong: false},
      %{name: "Shipping: Courier", detail: "", amount: "€5.00", strong: false},
      %{name: "Total", detail: "", amount: "€45.00", strong: true}
    ]

    %{
      "order_number" => "ORD-2026-0042",
      "order_status" => "Pending",
      "order_table_html" => table_html(rows),
      "order_text" => table_text(rows),
      "order_notes" => "",
      "delivery" => "Shipping: Courier — Example street 1, 10111, Tallinn, EE",
      "order_url" => "https://example.com/dashboard/orders/42",
      "admin_order_url" => "https://example.com/admin/billing/orders/42",
      "customer_name" => "Jane Doe",
      "customer_email" => "jane.doe@example.com",
      "customer_phone" => "+372 555 5555",
      "billing_address" => "Example street 1, 10111, Tallinn, EE"
    }
  end
end
