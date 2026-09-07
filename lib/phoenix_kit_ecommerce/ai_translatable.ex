defmodule PhoenixKitEcommerce.AITranslatable do
  @moduledoc """
  `PhoenixKitAI.Translatable` adapter for shop products.

  ## Resource identity

  `resource_type` is `"shop_product"`; `resource_uuid` is the product uuid.

  ## Fields

  `%{"title", "description", "body", "seo_title", "seo_description"}` from
  the source language (`Translations.get/3`), non-empty only. `"body"` maps
  to the schema's `body_html` (the shared prompt vocabulary uses `body`).
  The slug is NEVER sourced from or trusted to the AI — it is regenerated
  locally from the translated title, and only when the target language has
  no slug yet, so re-translations can't change published URLs. This is a
  write-once rule for the translation pipeline only: `regenerate_slug/2` is
  the explicit, one-off repair path for a slug already shaped by an older
  version of this adapter, and it always recomputes from the current title
  regardless of whether a slug exists. Callers doing a bulk repair are
  responsible for their own redirect/history bookkeeping — this module has
  none.

  ## Concurrency

  All languages share ONE product row's JSONB maps, so `put_translation/4`
  re-reads the row under `FOR UPDATE` and merges against the latest
  committed state (the publishing group-adapter pattern) — concurrent
  per-language jobs serialize on the row lock and never drop a sibling
  language. `update_product/2` / `update_product_translation/3` are
  deliberately NOT used here: they write a stale in-memory struct without a
  lock — the exact lost-update race this adapter must prevent.

  Slug uniqueness within the language is checked app-side (suffix on
  collision); there is no DB unique constraint on the JSONB slug map (core
  migration v47 dropped it), so the check is best-effort across rows.

  ## Prompt

  The seo fields are not in the shared translation prompt's vocabulary, so
  this adapter ships its own prompt (`ensure_prompt/0`, slug
  `phoenixkit-shop-product-translation`). Host forms must pass its uuid
  per job — the global `ai_translation_prompt_uuid` setting stays untouched.

  Requires the optional `phoenix_kit_ai` plugin: `ensure_prompt/0` returns
  `{:error, :ai_not_installed}` when it is absent, and the whole adapter is
  only reached through duck-typed discovery, which never runs without it.
  """

  # Structurally implements the `PhoenixKitAI.Translatable` behaviour, but we
  # DON'T declare `@behaviour` — phoenix_kit_ai is an optional dependency and a
  # declared behaviour would force it at compile time. Discovery is duck-typed
  # (`ai_translatables/0` + `PhoenixKitAI.Translatables`), so this module is
  # only ever exercised when the plugin is present; the guarded PhoenixKitAI
  # calls in ensure_prompt/0 are quietened for the plugin-absent build.
  @compile {:no_warn_undefined, PhoenixKitAI}

  import Ecto.Query, only: [where: 3, lock: 2, from: 2]

  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Translations

  @resource_type "shop_product"
  @prompt_name "PhoenixKit Shop Product Translation"
  # MUST equal slugify(@prompt_name): create_prompt derives the stored slug
  # from the NAME, so the idempotent get_prompt_by_slug re-read only finds
  # the row when the lookup slug matches that derived value. A mismatch makes
  # ensure_prompt/0 fail with :prompt_create_failed on every call after the
  # first (unique-name violation, then a slug miss).
  @prompt_slug "phoenixkit-shop-product-translation"

  # field name in the prompt/pipeline => schema field
  @field_map %{
    "title" => :title,
    "description" => :description,
    "body" => :body_html,
    "seo_title" => :seo_title,
    "seo_description" => :seo_description
  }

  @doc "The resource-type key this adapter registers under."
  def resource_type, do: @resource_type

  def fetch(@resource_type, product_uuid) when is_binary(product_uuid) do
    case repo().get(Product, product_uuid) do
      nil -> {:error, :resource_not_found}
      %Product{} = product -> {:ok, product}
    end
  end

  def fetch(_resource_type, _uuid), do: {:error, :resource_not_found}

  def source_fields(%Product{} = product, source_lang) do
    # Read the source language DIRECTLY, without Translations.get/3's
    # exact→default→first fallback: translating with the prompt saying
    # "from {{SourceLanguage}}" while feeding another language's text would
    # silently corrupt the result.
    @field_map
    |> Enum.map(fn {prompt_field, schema_field} ->
      {prompt_field, Map.get(Map.get(product, schema_field) || %{}, source_lang)}
    end)
    |> Enum.filter(fn {_k, v} -> is_binary(v) and String.trim(v) != "" end)
    |> Map.new()
  end

  def put_translation(%Product{uuid: uuid}, target_lang, fields, opts)
      when is_binary(target_lang) do
    translated =
      for {prompt_field, schema_field} <- @field_map,
          value = clean(fields[prompt_field]),
          value != nil,
          into: %{} do
        {schema_field, value}
      end

    if translated == %{} do
      {:error, :no_translated_fields}
    else
      case merge_translation(uuid, target_lang, translated) do
        {:ok, updated} = ok ->
          Events.broadcast_product_updated(updated)
          log_translated(updated, target_lang, opts)
          ok

        error ->
          error
      end
    end
  end

  @doc """
  Recomputes and stores `lang`'s slug from its CURRENT title, even when a
  slug already exists. Explicit, one-off repair path — bypasses the
  write-once rule `put_translation/4` enforces for the translation
  pipeline. Returns `{:error, :no_title}` when `lang` has no title, and
  `{:ok, %{old: slug, new: slug}}` (unchanged) when the recomputed slug
  equals the stored one. Broadcasts `Events.broadcast_product_updated/1`
  only when the slug actually changes.

  `opts[:dry_run]` (default `false`): when `true`, computes and returns the
  same `{:ok, %{old: old, new: new}}` result WITHOUT writing anything — no
  update, no broadcast. Lets a bulk repair task preview what would change.
  """
  @spec regenerate_slug(String.t(), String.t(), keyword()) ::
          {:ok, %{old: String.t() | nil, new: String.t()}} | {:error, term()}
  def regenerate_slug(product_uuid, lang, opts \\ [])
      when is_binary(product_uuid) and is_binary(lang) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    repo().transaction(fn ->
      query = Product |> where([p], p.uuid == ^product_uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        %Product{} = fresh -> do_regenerate_slug(fresh, lang, dry_run?)
      end
    end)
  end

  @doc """
  Idempotently creates this adapter's translation prompt and returns its
  uuid — host forms pass it per job instead of the shared default prompt.
  """
  @spec ensure_prompt() :: {:ok, String.t()} | {:error, term()}
  def ensure_prompt do
    if Code.ensure_loaded?(PhoenixKitAI) and function_exported?(PhoenixKitAI, :create_prompt, 1) do
      case PhoenixKitAI.get_prompt_by_slug(@prompt_slug) do
        nil -> create_prompt()
        prompt -> {:ok, prompt.uuid}
      end
    else
      {:error, :ai_not_installed}
    end
  end

  defp create_prompt do
    case PhoenixKitAI.create_prompt(prompt_attrs()) do
      {:ok, prompt} ->
        {:ok, prompt.uuid}

      {:error, _} ->
        # Lost a create race — re-read by slug.
        case PhoenixKitAI.get_prompt_by_slug(@prompt_slug) do
          nil -> {:error, :prompt_create_failed}
          prompt -> {:ok, prompt.uuid}
        end
    end
  end

  # -- internals ---------------------------------------------------------

  defp merge_translation(uuid, target_lang, translated) do
    repo().transaction(fn ->
      query = Product |> where([p], p.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        %Product{} = fresh -> write_merged(fresh, target_lang, translated)
      end
    end)
  end

  defp write_merged(%Product{} = fresh, target_lang, translated) do
    changes =
      translated
      |> Enum.reduce(%{}, fn {schema_field, value}, acc ->
        merged = Map.put(Map.get(fresh, schema_field) || %{}, target_lang, value)
        Map.put(acc, schema_field, merged)
      end)
      |> maybe_put_slug(fresh, target_lang, translated[:title])

    case fresh |> slug_changeset(changes) |> repo().update() do
      {:ok, updated} -> updated
      {:error, reason} -> repo().rollback(reason)
    end
  end

  # `Ecto.Changeset.change/2` skips `Product.changeset/2`, so the projection
  # pkey has to be registered here too. `unique_slug/3` checks the exact jsonb
  # key while V171's bucket is the BASE language (`en-US` folds to `en`), and
  # the check-then-write is not atomic across products anyway — both leave a
  # window where the trigger insert raises. Naming the constraint turns that
  # into `{:error, changeset}` instead of a Postgrex.Error escaping the job.
  defp slug_changeset(%Product{} = fresh, changes) do
    fresh
    |> Ecto.Changeset.change(changes)
    |> Ecto.Changeset.unique_constraint(:slug,
      name: "phoenix_kit_shop_product_slugs_pkey"
    )
  end

  defp do_regenerate_slug(%Product{} = fresh, lang, dry_run?) do
    case Map.get(fresh.title || %{}, lang) do
      title when is_binary(title) and title != "" ->
        slug_map = fresh.slug || %{}
        old_slug = Map.get(slug_map, lang)
        new_slug = title |> slug_base(slug_map, lang) |> unique_slug(lang, fresh.uuid)

        if dry_run? or new_slug == old_slug do
          %{old: old_slug, new: new_slug}
        else
          write_regenerated_slug(fresh, slug_map, lang, old_slug, new_slug)
        end

      _ ->
        repo().rollback(:no_title)
    end
  end

  defp write_regenerated_slug(%Product{} = fresh, slug_map, lang, old_slug, new_slug) do
    changes = %{slug: Map.put(slug_map, lang, new_slug)}

    case fresh |> slug_changeset(changes) |> repo().update() do
      {:ok, updated} ->
        Events.broadcast_product_updated(updated)
        %{old: old_slug, new: new_slug}

      {:error, reason} ->
        repo().rollback(reason)
    end
  end

  # A locally-generated slug from the translated title, ONLY when the target
  # language has none yet — re-translations never rewrite an existing slug.
  defp maybe_put_slug(changes, %Product{} = fresh, target_lang, translated_title) do
    slug_map = fresh.slug || %{}

    cond do
      Map.get(slug_map, target_lang) not in [nil, ""] ->
        changes

      translated_title in [nil, ""] ->
        changes

      true ->
        base = slug_base(translated_title, slug_map, target_lang)
        slug = unique_slug(base, target_lang, fresh.uuid)
        Map.put(changes, :slug, Map.put(slug_map, target_lang, slug))
    end
  end

  @slug_max_len 60
  @slug_head_split ~r/\s+[-–—]\s+|\|/u
  @slug_tail_digits ~r/-(\d{4,})$/

  # A URL slug from the translated title, capped to a sane length. Long SEO
  # titles pack multiple `|`- or spaced-dash-separated segments (title,
  # category breadcrumb, marketing tail); only the first (head) segment is
  # slug-worthy, mirroring the short en-US Shopify handle. Scripts with no
  # romanizer (CJK, Arabic, emoji) still slugify to "" — Cyrillic does not,
  # now that transliteration is the default.
  defp slug_base(translated_title, slug_map, target_lang) do
    # target_lang is the language the TRANSLATED title is in, so the slug must be
    # generated in it — a German translation wants ö -> oe, an Estonian one ö -> o.
    head = head_segment(translated_title)

    base =
      case head |> Product.slugify(target_lang) |> cap_word_boundary(@slug_max_len) do
        "" -> full_title_base(translated_title, slug_map, target_lang)
        slug -> slug
      end

    with_identity_tail(base, slug_map)
  end

  # The first non-blank segment before a `|` or a spaced dash (` - `, ` – `,
  # ` — `). Falls back to the whole (trimmed) title when every segment is
  # blank (a title made only of separators).
  defp head_segment(title) do
    title
    |> String.split(@slug_head_split)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> String.trim(title)
      segment -> segment
    end
  end

  # The head segment slugified to "" (e.g. CJK/Arabic-only head) falls back
  # to slugifying the FULL title, then to the default-language slug + a
  # language suffix, so the language always gets a non-empty per-language
  # slug instead of silently serving the default-language URL.
  defp full_title_base(translated_title, slug_map, target_lang) do
    case translated_title |> Product.slugify(target_lang) |> cap_word_boundary(@slug_max_len) do
      "" -> "#{strip_identity_tail(default_lang_slug(slug_map))}-#{target_lang}"
      slug -> slug
    end
  end

  # The fallback borrows the default-language slug, which usually already
  # carries the numeric identity tail. Strip it here so `with_identity_tail/2`
  # stays the ONE place that appends it — otherwise the tail lands twice
  # ("wooden-vase-22153-fr-22153").
  defp strip_identity_tail(slug), do: String.replace(slug, @slug_tail_digits, "")

  # Cuts to `max_len` at a word boundary: hard-cut to `max_len`, then drop
  # the trailing partial word (back to the last `-`) and any trailing `-`.
  # No `-` inside the cut string -> hard cut, unchanged. When the cut lands
  # exactly on a boundary (the character right after it is `-`), the sliced
  # string is already whole words — kept as is, nothing to drop.
  defp cap_word_boundary(slug, max_len) do
    if String.length(slug) <= max_len do
      slug
    else
      sliced = String.slice(slug, 0, max_len)

      cond do
        String.at(slug, max_len) == "-" ->
          sliced

        String.split(sliced, "-") == [sliced] ->
          sliced

        true ->
          sliced
          |> String.split("-")
          |> Enum.drop(-1)
          |> Enum.join("-")
          |> String.trim_trailing("-")
      end
    end
  end

  # Appends the default-language slug's numeric identity tail (`-<4+
  # digits>`, e.g. the Shopify-imported `-22153`) unless `base` already ends
  # with it. 4+ digits so `unique_slug/3`'s own `-2`/`-3` collision suffixes
  # are never mistaken for (and carried as) an identity tail.
  defp with_identity_tail(base, slug_map) do
    case identity_tail(slug_map) do
      nil -> base
      tail -> if String.ends_with?(base, tail), do: base, else: base <> tail
    end
  end

  defp identity_tail(slug_map) do
    with slug when is_binary(slug) <- default_lang_slug_value(slug_map),
         [_, digits] <- Regex.run(@slug_tail_digits, slug) do
      "-" <> digits
    else
      _ -> nil
    end
  end

  # The default-language slug (`Translations.default_language/0`'s key in
  # the slug map), else the first non-empty slug present.
  defp default_lang_slug_value(slug_map) do
    case Map.get(slug_map, Translations.default_language()) do
      slug when is_binary(slug) and slug != "" ->
        slug

      _ ->
        slug_map |> Map.values() |> Enum.find(&(is_binary(&1) and &1 != ""))
    end
  end

  defp default_lang_slug(slug_map), do: default_lang_slug_value(slug_map) || "product"

  # Best-effort per-language uniqueness (no DB constraint on the JSONB map).
  defp unique_slug(base, lang, own_uuid), do: unique_slug(base, lang, own_uuid, 0)

  defp unique_slug(base, lang, own_uuid, attempt) when attempt < 10 do
    candidate = if attempt == 0, do: base, else: "#{base}-#{attempt + 1}"

    taken? =
      repo().exists?(
        from(p in Product,
          where: fragment("?->>? = ?", p.slug, ^lang, ^candidate) and p.uuid != ^own_uuid
        )
      )

    if taken?, do: unique_slug(base, lang, own_uuid, attempt + 1), else: candidate
  end

  defp unique_slug(base, _lang, _own_uuid, attempt), do: "#{base}-#{attempt + 1}"

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp clean(_), do: nil

  defp log_translated(%Product{} = product, target_lang, opts) do
    Activity.log("shop.product.updated",
      mode: "auto",
      actor_uuid: opts[:actor_uuid],
      resource_type: "product",
      resource_uuid: product.uuid,
      metadata: %{"target_language" => target_lang, "source" => "ai_translation"}
    )
  end

  defp prompt_attrs do
    %{
      slug: @prompt_slug,
      name: @prompt_name,
      description: "Translates shop product fields (incl. SEO) between languages.",
      content: """
      You are translating fields of an e-commerce product from {{SourceLanguage}} to {{TargetLanguage}}.

      RULES:
      - Preserve formatting exactly (line breaks, spacing, HTML if present).
      - Do NOT translate text inside code blocks, inline code, or URLs.
      - Translate naturally and idiomatically — commercial tone, natural for a shop.
      - Keep any HTML tags and attributes unchanged; translate only human-visible text.
      - Keep brand names, materials and measurements as-is unless they have a standard translation.
      - Output ONLY the structured markers below — no commentary, no preface, no closing remarks.

      OUTPUT FORMAT — for each non-empty field in the SOURCE section below,
      emit ONE marker named after the field (uppercased), followed by the
      translation:

          ---TITLE---
          [translated title]

      Skip any field that is missing, blank, or still a literal placeholder
      (a value like `{{title}}` means the caller did not bind it) — do NOT
      emit a marker for it, and do NOT translate the placeholder text itself.

      === SOURCE ===

      Title: {{title}}

      Description: {{description}}

      Body: {{body}}

      Seo_title: {{seo_title}}

      Seo_description: {{seo_description}}
      """
    }
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
