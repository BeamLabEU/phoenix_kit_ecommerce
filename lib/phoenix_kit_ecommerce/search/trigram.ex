defmodule PhoenixKitEcommerce.Search.Trigram do
  @moduledoc """
  Whether the `pg_trgm` extension is installed, which decides if search may
  fall back to typo-tolerant matching.

  The answer is cached for 60 seconds in a `:persistent_term` (one query per
  minute instead of one per search); an extension installed later is noticed
  within a minute. Without the extension search still works: it only skips
  the typo fallback (`PhoenixKitEcommerce.Search.Query`).
  """

  @cache_key {__MODULE__, :available}
  @ttl_ms 60_000

  @doc "True when `pg_trgm` is installed in the database."
  @spec available?() :: boolean()
  def available? do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      {checked_at, value} when now - checked_at < @ttl_ms -> value
      _stale -> refresh(now)
    end
  end

  @doc "Test hook: pins the cached answer for the next 60 seconds."
  @spec put_cache(boolean()) :: :ok
  def put_cache(value) when is_boolean(value) do
    :persistent_term.put(@cache_key, {System.monotonic_time(:millisecond), value})
    :ok
  end

  @doc "Forgets the cached answer."
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp refresh(now) do
    value = installed?()
    :persistent_term.put(@cache_key, {now, value})
    value
  end

  defp installed? do
    case PhoenixKit.RepoHelper.repo().query(
           "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm')",
           []
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _other -> false
    end
  rescue
    _error -> false
  end
end
