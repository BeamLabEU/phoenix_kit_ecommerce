defmodule PhoenixKitEcommerce.Catalogue.ValueResolver do
  @moduledoc """
  Resolves a raw label — text as it arrives from an external source such
  as a Shopify option value ("Small", "Rouge") — to the value SLUG a
  catalogue attribute set already uses for that same choice, creating a
  new `draft` value when the set has none matching.

  Built for Block 7 (the Shopify sync writing catalogue attribute-set
  selections instead of raw strings); nothing in this fork calls it yet.

  ## Lookup order

  1. Slug match: `PhoenixKit.Utils.Slug.slugify(raw_label)` against every
     value's stored `:slug` in the set (draft values included — only
     `archived` ones are excluded by `AttributeSets.list_values/2`, so a
     value this resolver created as `draft` on a previous call is found
     again rather than duplicated).
  2. Exact-label match: the same whitespace-collapsed label against
     each value's `:title`.
  3. Miss: a new value is created.

  ## Why `Slug.slugify/1` computes the slug handed to `create_value/3`

  `AttributeSets.create_value/3` derives its own slug from the label only
  when no explicit `:slug` is given, via a hand-rolled ASCII-only
  fallback in that module with no transliteration — a non-Latin label
  there slugifies to `""` and gets a random suffix instead of a stable,
  readable slug. Passing the already-transliterated
  `PhoenixKit.Utils.Slug.slugify/1` result as the explicit `:slug`
  sidesteps that, AND keeps the value locatable by the same slug next
  time this resolver runs against the same label — a random suffix would
  not be reproducible across calls.

  ## Why the new value is created `draft`, and how

  `create_value/3` has no `:status` option — every value it creates is
  hardcoded `"published"`. `EntityData.bulk_update_status/3` is the only
  bulk alternative, and it skips per-record changeset validation and the
  per-record activity log — the wrong trade for one new row. The
  shortest correct path read from the API is: create (published), then
  `PhoenixKitEntities.EntityData.update/3` with `%{status: "draft"}` —
  `:status` is a cast-and-`validate_inclusion/3`-checked field on
  `EntityData.changeset/2`, so this is a normal, validated write, not a
  raw SQL patch. (There is no `PhoenixKitEntities.update_entity_data/2`
  — that name does not exist on the top-level module; the real API is
  the `EntityData.update/3` used here.)

  Storefront facets and pickers already exclude non-`published` values
  (`Query.attribute_set_counts/2` joins on `entity_data.status ==
  "published"`), so a `draft` value this resolver creates does not
  appear on the storefront until an admin publishes it.

  ## Set lookup never creates

  Sets are admin-managed blueprints (`AttributeSets.create_set/2`, a
  deliberate admin action) — `set_slug` must resolve to an EXISTING set
  or this returns `{:error, :set_not_found}`; nothing here ever creates
  a set.
  """

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities.EntityData}

  alias PhoenixKit.Utils.Slug
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEntities.EntityData

  @doc """
  Resolves `raw_label` to a value slug within the set named `set_slug`
  (bare or `"catalogue_set_"`-prefixed — the same lookup
  `Query.filter_by_metadata/2` uses). `opts` is forwarded to
  `AttributeSets.list_values/2` and `create_value/3` (e.g. `:actor_uuid`,
  `:mode` for the activity log).

  Returns `{:ok, slug}` for an existing match, `{:created, slug}` when a
  new `draft` value had to be made, `{:error, :set_not_found}` when
  `set_slug` doesn't resolve to a set (or whatever error `create_value/3`
  / the follow-up status update returns, on the rare write failure).
  """
  @spec resolve(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:created, String.t()} | {:error, :set_not_found | term()}
  def resolve(set_slug, raw_label, opts \\ [])
      when is_binary(set_slug) and is_binary(raw_label) do
    label = normalize_label(raw_label)

    case find_set(set_slug) do
      nil -> {:error, :set_not_found}
      set -> resolve_in_set(set, label, opts)
    end
  end

  defp resolve_in_set(set, label, opts) do
    slug = Slug.slugify(label)
    values = AttributeSets.list_values(set, opts)

    cond do
      value = Enum.find(values, &(&1.slug == slug)) ->
        {:ok, value.slug}

      value = Enum.find(values, &(&1.title == label)) ->
        {:ok, value.slug}

      true ->
        create_draft_value(set, label, slug, opts)
    end
  end

  defp create_draft_value(set, label, slug, opts) do
    with {:ok, value} <- AttributeSets.create_value(set, %{label: label, slug: slug}, opts),
         {:ok, drafted} <- EntityData.update(value, %{status: "draft"}) do
      {:created, drafted.slug}
    end
  end

  defp normalize_label(raw_label) do
    raw_label
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  # Mirrors `Query.set_uuid_for_key/1`'s lookup (private there, and out
  # of scope for this task's file list) — the set's blueprint `:name`,
  # bare or "catalogue_set_"-prefixed. Needs the full struct, not just
  # the uuid Query resolves to, since `list_values/2`/`create_value/3`
  # both take the set struct.
  defp find_set(set_slug) do
    Enum.find(
      AttributeSets.list_sets(),
      &(&1.name == set_slug or &1.name == "catalogue_set_" <> set_slug)
    )
  end
end
