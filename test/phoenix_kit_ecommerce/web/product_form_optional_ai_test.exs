defmodule PhoenixKitEcommerce.Web.ProductFormOptionalAITest do
  use ExUnit.Case, async: false

  @form PhoenixKitEcommerce.Test.ProductFormWithoutAI

  test "the product form compiles when the optional AI modules are absent" do
    source = File.read!("lib/phoenix_kit_ecommerce/web/product_form.ex")

    # Compile the real form against a missing namespace, even in builds that
    # have the optional dependency. A separate form leaves the running one intact.
    source =
      source
      |> String.replace("PhoenixKitEcommerce.Web.ProductForm", inspect(@form))
      |> String.replace("PhoenixKitAI", "PhoenixKitEcommerce.Test.MissingAI")

    on_exit(fn ->
      :code.delete(@form)
      :code.purge(@form)
    end)

    assert [{@form, _bytecode}] = Code.compile_string(source, "product_form_without_ai.ex")
    assert function_exported?(@form, :mount, 3)
    refute function_exported?(@form, :apply_translation, 4)
  end
end
