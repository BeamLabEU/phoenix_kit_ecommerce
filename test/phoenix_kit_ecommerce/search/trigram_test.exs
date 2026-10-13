defmodule PhoenixKitEcommerce.Search.TrigramTest do
  # async: false - the answer is cached in a process-global :persistent_term.
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce.Search.Trigram
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    Trigram.reset_cache()
    on_exit(&Trigram.reset_cache/0)
    :ok
  end

  defp installed? do
    %{rows: [[installed]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm')")

    installed
  end

  test "available?/0 reports whether pg_trgm is installed in this database" do
    assert Trigram.available?() == installed?()
  end

  test "put_cache/1 overrides the answer until reset_cache/0" do
    Trigram.put_cache(false)
    assert Trigram.available?() == false

    Trigram.put_cache(true)
    assert Trigram.available?() == true

    Trigram.reset_cache()
    assert Trigram.available?() == installed?()
  end
end
