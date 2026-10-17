defmodule PhoenixKitEcommerce.API.SetAvailability do
  @moduledoc """
  `ecommerce.set_availability`: the visibility and the made-to-order flag of
  products by reference. Same shape as `ecommerce.set_prices`: the catalogue
  source only, a batch write limited to the paths a row changes, a preview
  with `ctx.dry_run?`.

  It has no `danger` function: no value it writes is dangerous by itself
  (publishing is refused without a price instead), and a batch with more rows
  than `api_confirm_batch_over` is held by core's executor for every admin
  write tool. Its dry run says so: `requires_confirmation` is that row
  threshold alone.
  """

  alias PhoenixKitEcommerce.API.{AvailabilityPlan, Batch, Gate, Rows}

  @tool "ecommerce.set_availability"

  @doc "Handler of the tool."
  @spec run(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | Gate.refusal()
  def run(input, ctx) do
    with {:ok, rows} <- plan_rows(input) do
      if Map.get(ctx, :dry_run?, false) do
        {:preview, rows |> Batch.preview() |> Batch.with_confirmation(rows),
         Batch.fingerprint(rows)}
      else
        {:ok, rows |> Batch.write(ctx, @tool) |> Batch.render()}
      end
    end
  end

  defp plan_rows(input) do
    with {:ok, catalogue_uuid} <- Gate.check(input) do
      shopify? = PhoenixKitEcommerce.shopify_enabled?()
      {:ok, input["items"] |> Batch.load(catalogue_uuid) |> Batch.plan(&plan_row(&1, shopify?))}
    end
  end

  defp plan_row(%{item: item, input: input}, shopify?) do
    case AvailabilityPlan.plan(input, item, shopify_enabled?: shopify?) do
      {:ok, plan} -> {:ok, plan}
      {:error, errors} -> {:error, Rows.invalid(errors)}
    end
  end
end
