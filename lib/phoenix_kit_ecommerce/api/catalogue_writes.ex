defmodule PhoenixKitEcommerce.API.CatalogueWrites do
  @moduledoc """
  The one place the admin tools write catalogue items through the catalogue's
  batch update (`Catalogue.update_items/2`). The rest of the API
  code does not know the catalogue's argument or return shape: if it
  differs from what is assumed here, this module is the only one to change.

  The catalogue takes `{item_uuid, attrs, row_opts}` and answers
  `{:ok, [{item_uuid, {:updated, item} | {:unchanged, item} | {:error, why}}]}`
  in the order given; `row_opts` override the call's options for that row,
  which is how each row owns exactly the `data` paths it writes.
  """

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  require Logger

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.{Meta, Rows}

  @type answer :: {:ok, struct()} | {:unchanged, struct()} | {:error, Rows.t()}

  @doc """
  Updates `entries` (`[{item, attrs, row_opts}]`) in one batch and answers one
  result per entry, in order. `opts` go to the catalogue unchanged
  (`:actor_uuid`, `:log_metadata`, `:mode`, `:skip_derive`); `row_opts` are
  `:data_owned_paths` and `:logged_data_paths`.
  """
  @spec update_rows([{struct(), map(), keyword()}], keyword()) :: [answer()]
  def update_rows([], _opts), do: []

  def update_rows(entries, opts) when is_list(entries) do
    rows = Enum.map(entries, fn {item, attrs, row_opts} -> {item.uuid, attrs, row_opts} end)

    case Catalogue.update_items(rows, opts) do
      {:ok, outcomes} when is_list(outcomes) ->
        by_uuid = Map.new(outcomes)

        Enum.map(entries, fn {item, _attrs, _row_opts} ->
          item.uuid |> then(&Map.get(by_uuid, &1)) |> normalize(opts)
        end)

      {:error, reason} ->
        # The term can carry SQL fragments, constraint names or driver text,
        # and submitted values: log and answer get only a class.
        log_failure("update_items", opts, reason)
        failed(entries, "The batch could not be saved.", reason_class(reason))
    end
  end

  defp normalize({:updated, item}, _opts), do: {:ok, item}
  defp normalize({:unchanged, item}, _opts), do: {:unchanged, item}

  defp normalize({:error, %Ecto.Changeset{} = changeset}, _opts),
    do: {:error, Rows.from_changeset(changeset)}

  defp normalize({:error, :not_found}, _opts),
    do: {:error, Rows.error(:not_found, "The product no longer exists.")}

  defp normalize({:error, other}, opts) do
    log_failure("a row of update_items", opts, other)

    {:error,
     Rows.error(:validation_failed, "The product could not be saved.", %{
       "reason" => reason_class(other)
     })}
  end

  defp normalize(nil, _opts),
    do: {:error, Rows.error(:validation_failed, "The catalogue gave no answer for this row.")}

  defp failed(entries, message, class) do
    Enum.map(entries, fn _entry ->
      {:error, Rows.error(:validation_failed, message, %{"reason" => class})}
    end)
  end

  # A short stable class for the answer; the term itself never leaves the log.
  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(_reason), do: "unexpected"

  defp log_failure(what, opts, reason) do
    request_id = get_in(Keyword.get(opts, :log_metadata, %{}), ["request_id"])

    Logger.error(
      "[API.CatalogueWrites] request #{request_id}: #{what} failed: " <> Meta.term_class(reason)
    )
  end
end
