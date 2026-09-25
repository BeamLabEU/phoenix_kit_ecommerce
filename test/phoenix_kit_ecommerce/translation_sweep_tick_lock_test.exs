defmodule PhoenixKitEcommerce.TranslationSweepTickLockTest do
  @moduledoc """
  Two direct sweep ticks at once — two tabs pressing Run sweep — must not
  both run: the second answers `:sweep_running`. The sandbox cannot race,
  so a second, real connection holds the tick lock and the tick is asked.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.TranslationSweepWorker

  @key "phoenix_kit_ecommerce:translation_sweep_tick"

  test "a tick while another holds the lock answers sweep_running" do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
    {:ok, conn} = Postgrex.start_link(opts)
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [@key])

    assert {:sweep_running, %{}} = TranslationSweepWorker.run_manual_tick()

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [@key])
    {reason, _info} = TranslationSweepWorker.run_manual_tick()
    refute reason == :sweep_running
  end
end
