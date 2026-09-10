defmodule PhoenixKitEcommerce.Catalogue.ShopStatusColumnTest do
  @moduledoc """
  Level 1 — pure/component tests, no database required.

  `ShopStatusColumn` renders the catalogue admin's "Shop status" column —
  the owner's complaint was that the catalogue's own `status` and the
  shop's `data["ecommerce"]["shop_status"]` are two independent signals
  and only one showed on screen, so an item could be invisible on the
  storefront for a reason the admin screen never surfaced (see
  `PhoenixKitEcommerce.Catalogue.Extension` moduledoc / PR description).
  These tests cover the column's shape, every defensive read case, and
  that agreement/each direction of disagreement renders distinguishably.

  Assertions read the cell's own `data-catalogue-status="..."` /
  `data-shop-status="..."` / `data-contradiction="..."` attributes
  instead of matching badge text, since two badges' rendered labels
  ("Active", "Unknown", ...) can otherwise collide in one cell's HTML.
  """

  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe, as: HtmlSafe
  alias PhoenixKitEcommerce.Catalogue.ShopStatusColumn

  # ============================================================
  # Shape — what `PhoenixKitCatalogue.Extensions.columns/1` accepts
  # (id: binary without ":", label: 0-arity fn, render: 1-arity fn).
  # See `PhoenixKitCatalogue.Extension.column/0`'s typedoc (unreleased
  # branch, read for the contract — not depended on here).
  # ============================================================

  describe "item_columns/0" do
    test "returns exactly one column shaped for the catalogue extension slot" do
      assert [%{id: id, label: label, render: render}] = ShopStatusColumn.item_columns()
      assert is_binary(id)
      refute id == ""
      refute String.contains?(id, ":")
      assert is_function(label, 0)
      assert is_function(render, 1)
    end

    test "label/0 resolves through PhoenixKitEcommerce.Gettext" do
      [%{label: label}] = ShopStatusColumn.item_columns()
      assert label.() == "Shop status"

      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "de")
      assert label.() == "Shop-Status"
    after
      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "en")
    end
  end

  describe "category_columns/0" do
    test "returns exactly one column shaped for the catalogue extension slot" do
      assert [%{id: id, label: label, render: render}] = ShopStatusColumn.category_columns()
      assert is_binary(id)
      refute id == ""
      refute String.contains?(id, ":")
      assert is_function(label, 0)
      assert is_function(render, 1)
    end

    test "label/0 resolves through PhoenixKitEcommerce.Gettext" do
      [%{label: label}] = ShopStatusColumn.category_columns()
      assert label.() == "Shop status"

      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "fr")
      assert label.() == "Statut de la boutique"
    after
      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "en")
    end
  end

  # ============================================================
  # Defensive reads of data["ecommerce"]["shop_status"]
  # ============================================================

  defp render_cell(record) do
    [%{render: render}] = ShopStatusColumn.item_columns()
    render.(record) |> rendered_to_string()
  end

  defp catalogue_status_attr(html) do
    [_, value] = Regex.run(~r/data-catalogue-status="([^"]*)"/, html)
    value
  end

  defp shop_status_attr(html) do
    [_, value] = Regex.run(~r/data-shop-status="([^"]*)"/, html)
    value
  end

  defp contradiction_attr(html) do
    [_, value] = Regex.run(~r/data-contradiction="([^"]*)"/, html)
    value
  end

  describe "defensive reads — none may raise, none render a misleading active" do
    test "absent data entirely (bare struct-like map with no :data key)" do
      html = render_cell(%{status: "active"})
      assert shop_status_attr(html) == "unknown"
    end

    test "data present but nil" do
      html = render_cell(%{status: "active", data: nil})
      assert shop_status_attr(html) == "unknown"
    end

    test "data present, absent ecommerce key" do
      html = render_cell(%{status: "active", data: %{}})
      assert shop_status_attr(html) == "unknown"
    end

    test "ecommerce key present but not a map" do
      html = render_cell(%{status: "active", data: %{"ecommerce" => "not-a-map"}})
      assert shop_status_attr(html) == "unknown"
    end

    test "ecommerce map present, absent shop_status key" do
      html = render_cell(%{status: "active", data: %{"ecommerce" => %{}}})
      assert shop_status_attr(html) == "unknown"
    end

    test "shop_status present but non-binary (integer)" do
      html = render_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => 123}}})
      assert shop_status_attr(html) == "unknown"
    end

    test "shop_status present but non-binary (map)" do
      html =
        render_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => %{}}}})

      assert shop_status_attr(html) == "unknown"
    end

    test "shop_status present but non-binary (nil)" do
      html = render_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => nil}}})
      assert shop_status_attr(html) == "unknown"
    end

    test "shop_status an unrecognized string value renders that value, not a crash" do
      html =
        render_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => "bogus"}}})

      assert shop_status_attr(html) == "bogus"
    end

    test "catalogue status itself absent/nil normalizes to unknown, never a bare crash" do
      html = render_cell(%{status: nil, data: %{"ecommerce" => %{"shop_status" => "active"}}})
      assert catalogue_status_attr(html) == "unknown"
      assert shop_status_attr(html) == "active"
    end

    test "catalogue status non-binary normalizes to unknown, does not raise" do
      html = render_cell(%{status: 42, data: %{"ecommerce" => %{"shop_status" => "active"}}})
      assert catalogue_status_attr(html) == "unknown"
    end
  end

  # ============================================================
  # Agreement / each direction of disagreement rendering distinguishably
  # ============================================================

  describe "agreement and disagreement render distinguishably" do
    test "catalogue active + shop active — agree, visible, no warning" do
      html =
        render_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => "active"}}})

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
    end

    test "catalogue inactive + shop draft — agree (both not visible), no warning" do
      html =
        render_cell(%{status: "inactive", data: %{"ecommerce" => %{"shop_status" => "draft"}}})

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
    end

    test "catalogue active + shop draft — contradiction: live in catalogue, not for sale" do
      html =
        render_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => "draft"}}})

      assert html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "true"
    end

    test "catalogue inactive + shop active — contradiction: reverse direction" do
      html =
        render_cell(%{status: "inactive", data: %{"ecommerce" => %{"shop_status" => "active"}}})

      assert html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "true"
    end

    test "the contradiction hint resolves through PhoenixKitEcommerce.Gettext" do
      record = %{status: "active", data: %{"ecommerce" => %{"shop_status" => "draft"}}}

      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "de")
      html = render_cell(record)
      assert html =~ ~s(title="Katalogstatus und Shop-Status stimmen nicht überein)
    after
      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "en")
    end
  end

  describe "no record-scoped id attribute (renders in table AND card DOM in one page load)" do
    test "the cell never carries an id= attribute" do
      html =
        render_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => "draft"}}})

      refute html =~ ~s( id=")
    end
  end

  defp rendered_to_string(%Phoenix.LiveView.Rendered{} = rendered) do
    rendered |> HtmlSafe.to_iodata() |> IO.iodata_to_binary()
  end
end
