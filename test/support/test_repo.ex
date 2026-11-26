defmodule PhoenixKitEcommerce.Test.Repo do
  @moduledoc """
  Test-only Ecto repo for integration tests.

  Configured in `config/test.exs`, started by `test_helper.exs`.
  Uses `Ecto.Adapters.SQL.Sandbox` for transaction-based test isolation.
  """
  use Ecto.Repo,
    otp_app: :phoenix_kit_ecommerce,
    adapter: Ecto.Adapters.Postgres

  @doc """
  A test can make the repo refuse the queries of one table in its own
  process (`Process.put(:test_repo_refuse_source, "oban_jobs")`): the query
  raises before it reaches the database. A statement that fails in the
  database would break the sandbox's transaction for the rest of the test.
  """
  @impl true
  def prepare_query(_operation, query, opts) do
    case Process.get(:test_repo_refuse_source) do
      nil -> {query, opts}
      source -> refuse_source(query, source, opts)
    end
  end

  defp refuse_source(%Ecto.Query{from: %{source: {source, _schema}}}, source, _opts),
    do: raise(DBConnection.ConnectionError, "refused by the test: #{source}")

  defp refuse_source(query, _source, opts), do: {query, opts}
end
