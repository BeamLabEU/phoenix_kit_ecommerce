defmodule PhoenixKitEcommerce.Regression.PromUaSlugTest do
  @moduledoc """
  Prom.ua is a Ukrainian marketplace, so its rows are Cyrillic and often carry
  neither a product URL nor a unique identifier — the last-resort slug is the
  only identity those listings have, and the upsert matches on it.
  """
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Import.PromUaFormat

  defp write_csv(rows) do
    path = Path.join(System.tmp_dir!(), "prom-#{System.unique_integer([:positive])}.csv")
    File.write!(path, Enum.join(rows, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp slugs_for(rows) do
    path =
      write_csv([
        "Назва_позиції,Ціна,Номер_групи,Унікальний_ідентифікатор,Продукт_на_сайті" | rows
      ])

    path
    |> PromUaFormat.parse_and_transform(%{}, nil, [])
    |> Enum.map(fn attrs -> attrs.slug |> Map.values() |> List.first() end)
  end

  @tag :requires_core_transliteration
  test "a Cyrillic listing gets a real slug" do
    [slug] = slugs_for(["Кашпо,100,12,,"]) |> Enum.uniq() |> then(&[List.first(&1)])

    assert slug =~ "kashpo", "a Cyrillic name used to slugify to an empty string"
  end

  @tag :requires_core_transliteration
  test "listings that transliterate the same still get distinct slugs" do
    # Transliteration is lossy: Ганок and Ґанок both give "ganok". The upsert
    # matches on this slug, so without a discriminator the second listing
    # OVERWRITES the first instead of importing beside it.
    slugs = slugs_for(["Ганок,100,12,,", "Ґанок,200,12,,"])

    assert length(Enum.uniq(slugs)) == 2, "two distinct listings collapsed onto one slug"
  end

  @tag :requires_core_transliteration
  test "the same listing slugs identically on a second import" do
    assert slugs_for(["Кашпо керамічне,100,12,,"]) ==
             slugs_for(["Кашпо керамічне,100,12,,"])
  end

  test "a listing with a unique identifier still uses it" do
    [slug] = slugs_for(["Кашпо,100,12,ABC-9,"])

    assert slug == "prom-ABC-9"
  end
end
