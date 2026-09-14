defmodule PhoenixKitEcommerce.TranslationTabsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The pure merge helper both admin forms save through.

  Editing a default-language field that was non-empty at mount was silently
  discarded: `build_translations_map/2` snapshots every language the entity has
  a value in — the default one included — and `merge_translations_to_attrs/5`
  then reduced over that snapshot AFTER writing the main form's value, putting
  the mount-time text back over the edit. The save reported success and the old
  text returned (issue #27).

  Both halves are pinned here on purpose: a field that was EMPTY at mount has
  no snapshot entry and always saved correctly, so a test that only covers the
  empty case passes with the bug still in place.
  """

  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Web.Components.TranslationTabs, as: TT

  @default "en-US"

  describe "merge_translations_to_attrs/5 — the default language" do
    test "an edit to a field that was NON-EMPTY at mount lands" do
      entity = %Product{title: %{@default => "Old title"}}
      snapshot = TT.build_translations_map(entity, [:title])

      # The snapshot really does carry the default language — that is the
      # precondition of the bug, so assert it rather than assume it.
      assert %{@default => %{"title" => "Old title"}} = snapshot

      attrs =
        TT.merge_translations_to_attrs(
          entity,
          snapshot,
          %{"title" => "NEW TITLE typed by user"},
          @default,
          [:title]
        )

      assert attrs.title == %{@default => "NEW TITLE typed by user"}
    end

    test "an edit to a field that was EMPTY at mount still lands" do
      entity = %Product{title: %{}}
      snapshot = TT.build_translations_map(entity, [:title])

      attrs =
        TT.merge_translations_to_attrs(entity, snapshot, %{"title" => "NEW"}, @default, [
          :title
        ])

      assert attrs.title == %{@default => "NEW"}
    end

    test "clearing it clears the stored value instead of restoring the snapshot" do
      entity = %Product{title: %{@default => "Old title"}}
      snapshot = TT.build_translations_map(entity, [:title])

      attrs =
        TT.merge_translations_to_attrs(entity, snapshot, %{"title" => ""}, @default, [:title])

      refute Map.has_key?(attrs.title, @default)
    end

    test "a field the main form did not submit keeps its stored value" do
      entity = %Product{title: %{@default => "Old title"}}
      snapshot = TT.build_translations_map(entity, [:title])

      attrs = TT.merge_translations_to_attrs(entity, snapshot, %{}, @default, [:title])

      assert attrs.title == %{@default => "Old title"}
    end

    test "a field submitted as nil keeps its stored value instead of being wiped" do
      # The product form has no main-field input for body_html / seo_title /
      # seo_description — they exist only in the translation tabs — so those
      # keys reach the merge with a nil value. nil is "not submitted", not
      # "cleared": once the default language stopped being restored from the
      # snapshot, treating it as cleared wiped imported content on every save.
      entity = %Product{
        title: %{@default => "Old title"},
        body_html: %{@default => "<p>Imported body</p>"},
        seo_title: %{@default => "Buy it"}
      }

      snapshot = TT.build_translations_map(entity, [:title, :body_html, :seo_title])

      attrs =
        TT.merge_translations_to_attrs(
          entity,
          snapshot,
          %{"title" => "New title", "body_html" => nil, "seo_title" => nil},
          @default,
          [:title, :body_html, :seo_title]
        )

      assert attrs.title == %{@default => "New title"}
      assert attrs.body_html == %{@default => "<p>Imported body</p>"}
      assert attrs.seo_title == %{@default => "Buy it"}
    end
  end

  describe "merge_translations_to_attrs/5 — the other languages" do
    test "translations still merge, and every field moves together" do
      # Guards the over-correction: a fix that dropped the whole snapshot
      # instead of just its default-language entry would lose "ru" here.
      entity = %Product{
        title: %{@default => "Old title", "ru" => "Старое название"},
        slug: %{@default => "old-title", "ru" => "staroe"}
      }

      snapshot = TT.build_translations_map(entity, [:title, :slug])

      attrs =
        TT.merge_translations_to_attrs(
          entity,
          snapshot,
          %{"title" => "New title", "slug" => "new-title"},
          @default,
          [:title, :slug]
        )

      assert attrs.title == %{@default => "New title", "ru" => "Старое название"}
      assert attrs.slug == %{@default => "new-title", "ru" => "staroe"}
    end

    test "a translation edited in this submission wins over its snapshot" do
      entity = %Product{title: %{@default => "Old", "ru" => "Старое"}}
      snapshot = TT.build_translations_map(entity, [:title])
      edited = Map.put(snapshot, "ru", %{"title" => "Новое"})

      attrs =
        TT.merge_translations_to_attrs(entity, edited, %{"title" => "New"}, @default, [
          :title
        ])

      assert attrs.title == %{@default => "New", "ru" => "Новое"}
    end
  end

  describe "the category form's own field" do
    test "name behaves the same way" do
      entity = %Category{name: %{@default => "Old name"}}
      snapshot = TT.build_translations_map(entity, [:name])

      attrs =
        TT.merge_translations_to_attrs(entity, snapshot, %{"name" => "New name"}, @default, [
          :name
        ])

      assert attrs.name == %{@default => "New name"}
    end
  end
end
