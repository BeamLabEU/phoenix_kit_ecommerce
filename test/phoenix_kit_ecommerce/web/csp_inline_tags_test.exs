defmodule PhoenixKitEcommerce.Web.CSPInlineTagsTest do
  @moduledoc """
  The module's markup works under a host Content-Security-Policy that allows inline code by
  nonce only (`script-src 'self' 'nonce-…'`, see core's `guides/content-security-policy.md`):

    * no inline event handler (`onclick="…"`, `onerror="…"`) and no `javascript:` URL, in `lib/`
      or in the module's JS: no nonce can be put on an attribute. The markup names what it wants
      with a `data-pkec-*` attribute and `priv/static/assets/phoenix_kit_ecommerce.js` does it;
    * no inline `<script>` or `<style>`: the module renders none, and a new one needs the host's
      nonce (`PhoenixKitWeb.CSP.nonce/1`, feature-detected, as core releases before the nonce
      support have no such module).

  Modelled on core's `test/phoenix_kit_web/csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Mix.Tasks.Compile.PhoenixKitJsSources
  alias PhoenixKitEcommerce.Web.Components.CatalogSidebar

  @bundle "priv/static/assets/phoenix_kit_ecommerce.js"
  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  # Files that handle `<script>` / `<style>` as text, not as markup they render.
  @tags_as_data [
    # Strips those elements from imported product descriptions.
    "lib/phoenix_kit_ecommerce/html_to_markdown.ex"
  ]

  @tag_opening ~r/<(script|style)\b[^>]*>/si

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!(
             "\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]",
             "i"
           )
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path not in @tags_as_data,
          {opening, number} <- tag_openings(path),
          not (opening =~ ~r/\bsrc\s*=/i),
          not (opening =~ "CSP.nonce(" or opening =~ "CSP.attr("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without the host's nonce:\n" <> Enum.join(offenders, "\n")
  end

  # `nonce={…}` is HEEx. In a plain string it renders literally, which the browser cannot match.
  test "a `nonce={…}` attribute in an .ex file sits inside a ~H template" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          lines = path |> File.read!() |> code_lines(),
          {line, number} <- lines,
          line =~ "nonce={PhoenixKitWeb.CSP",
          not in_heex?(lines, number),
          do: "#{path}:#{number}"

    assert offenders == [],
           "write `<style\#{PhoenixKitWeb.CSP.attr(:style)}>` in a plain string:\n" <>
             Enum.join(offenders, "\n")
  end

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `data-pkec-*` attribute handled in " <>
             "#{@bundle}, or a `phx-` binding):\n" <> Enum.join(offenders, "\n")
  end

  test "the module's JS builds no markup with an inline handler and no <style> or <script>" do
    offenders =
      for {line, number} <- @bundle |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not (line =~ ~r{^\s*(//|\*)}),
          line =~ ~r/\son[a-z]+=\\?["']/i or
            line =~ ~r/createElement\(["'](?:style|script)["']\)/i or
            line =~ ~r/["'`]<(?:style|script)\b/i or line =~ ~r/\bjavascript:/i,
          do: "#{@bundle}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  test "the scans see what they are for" do
    assert ~s(<img onerror={"this.src='x'"} />) =~ @handler
    assert ~s|<button onClick="go()">| =~ @handler
    assert ~s|<a href="javascript:void(0)">| =~ @js_url
    refute ~s(<button phx-click="go" data-pkec-no-toggle>) =~ @handler
    assert Regex.match?(@tag_opening, "<style>\n.a{}")
    assert Regex.match?(@tag_opening, "<SCRIPT>alert(1)</SCRIPT>")
  end

  describe "the JS that replaces the handlers" do
    test "is declared by js_sources/0 and shipped in the package" do
      assert [
               %{app: :phoenix_kit_ecommerce, file: file, global: "PhoenixKitEcommerceHooks"} =
                 entry
             ] =
               PhoenixKitEcommerce.js_sources()

      assert Path.join("priv", file) == @bundle
      assert File.regular?(@bundle)
      assert "priv/static" in Mix.Project.config()[:package][:files]

      if Code.ensure_loaded?(PhoenixKitJsSources) and
           function_exported?(PhoenixKitJsSources, :normalize_entry, 1) do
        assert %{app: :phoenix_kit_ecommerce, file: ^file, global: "PhoenixKitEcommerceHooks"} =
                 PhoenixKitJsSources.normalize_entry(entry)
      end
    end

    test "handles every data-pkec-* attribute the markup uses" do
      bundle = File.read!(@bundle)

      used =
        for path <- Path.wildcard("lib/**/*.{ex,heex}"),
            [attr] <- Regex.scan(~r/data-pkec-[a-z-]+/, File.read!(path)),
            uniq: true,
            do: attr

      assert "data-pkec-img-fallback" in used
      assert "data-pkec-no-toggle" in used

      for attr <- used do
        assert bundle =~ ~s("#{attr}") or bundle =~ "[#{attr}]",
               "#{attr} is rendered but #{@bundle} has no listener for it"
      end
    end

    @tag :node
    test "behaves (node test/js/storefront.test.cjs)" do
      case System.find_executable("node") do
        nil ->
          :ok

        node ->
          {output, status} =
            System.cmd(node, ["--test", "test/js/storefront.test.cjs"], stderr_to_stdout: true)

          assert status == 0, output
      end
    end
  end

  test "the per-filter clear button names the fold guard and carries no handler" do
    html =
      render_component(&CatalogSidebar.filter_section/1,
        filter: %{
          "key" => "vendor",
          "type" => "vendor",
          "label" => "Vendor",
          "enabled" => true,
          "position" => 0
        },
        values: [%{value: "Acme", count: 1}],
        active: ["Acme"]
      )

    assert html =~ ~s(phx-click="clear_filter")
    assert html =~ "data-pkec-no-toggle"
    refute html =~ "onclick"
  end

  # The nearest heredoc opener above the line is a `~H`.
  defp in_heex?(lines, number) do
    lines
    |> Enum.take(number - 1)
    |> Enum.reverse()
    |> Enum.find(fn {line, _} -> line =~ ~s(""") end)
    |> case do
      {opener, _} -> opener =~ ~s(~H""")
      nil -> false
    end
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  # Lines of the file with `@moduledoc`/`@doc` heredocs and HEEx comments blanked: a tag there
  # is an example, not markup.
  defp code_lines(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
