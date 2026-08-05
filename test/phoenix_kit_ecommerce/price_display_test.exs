defmodule PhoenixKitEcommerce.PriceDisplayTest do
  @moduledoc """
  The price-unit / "From" feature: storage, context contract, and the two
  paths that would silently erase an admin's settings (a CSV re-import and
  an unrelated product-form save).
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.PriceDisplay

  @key PriceDisplay.metadata_key()

  # Slug lookup normalizes a base code to its dialect ("en" -> "en-US"), so
  # a slug map must be keyed the way the RESOLVER will look it up. (When the
  # shop's default language is a bare base code the two disagree - see
  # FOLLOW_UP; keying via the resolver keeps this test on the production
  # path rather than pinning the mismatch.)
  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp product_attrs(extra \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        "title" => %{"en" => "Consulting #{n}", lang() => "Consulting #{n}"},
        "slug" => %{lang() => "consulting-#{n}"},
        "price" => Decimal.new("40.00"),
        "status" => "active",
        "currency" => "USD"
      },
      extra
    )
  end

  defp with_display(unit, from?) do
    product_attrs(%{"metadata" => %{@key => PriceDisplay.build(unit, from?)}})
  end

  describe "storage" do
    test "build/2 drops blanks, trims, bounds length, and collapses to empty" do
      assert PriceDisplay.build(%{"en" => "  per hour  "}, false) ==
               %{"unit" => %{"en" => "per hour"}, "from" => false}

      assert PriceDisplay.build(%{"en" => ""}, false) == %{}
      assert PriceDisplay.build(%{}, false) == %{}
      # A "From" flag alone is meaningful (a service quoted from a rate).
      assert PriceDisplay.build(%{}, true) == %{"unit" => %{}, "from" => true}

      long = String.duplicate("x", 100)
      %{"unit" => %{"en" => stored}} = PriceDisplay.build(%{"en" => long}, false)
      assert String.length(stored) == 32
    end

    test "settings/1 tolerates absent, malformed and partial data" do
      assert %{unit: %{}, from: false} = PriceDisplay.settings(%{})
      assert %{unit: %{}, from: false} = PriceDisplay.settings(nil)
      assert %{unit: %{}, from: false} = PriceDisplay.settings(%{@key => %{"unit" => "nope"}})
      assert %{unit: %{}, from: true} = PriceDisplay.settings(%{@key => %{"from" => true}})
    end

    test "unit_for/2 falls back to the default language" do
      metadata = %{@key => %{"unit" => %{"en" => "per hour"}, "from" => false}}

      assert PriceDisplay.unit_for(metadata, "en") == "per hour"
      # Unknown language falls back rather than rendering nothing.
      assert PriceDisplay.unit_for(metadata, "zz") == "per hour"
      assert PriceDisplay.unit_for(%{}, "en") == nil
    end
  end

  describe "render contexts" do
    test "catalog shows the unit, and From only when earned" do
      {:ok, plain} = Shop.create_product(product_attrs())
      {:ok, united} = Shop.create_product(with_display(%{"en" => "per hour"}, false))
      {:ok, from} = Shop.create_product(with_display(%{"en" => "per hour"}, true))

      # No settings at all renders exactly what it always did.
      assert PriceDisplay.render(plain, nil, :catalog, language: "en") == "$40.00"

      assert PriceDisplay.render(united, nil, :catalog, language: "en") == "$40.00 per hour"

      assert PriceDisplay.render(from, nil, :catalog, language: "en") == "From $40.00 per hour"
    end

    test "snapshot contexts never say From and use the stored unit" do
      {:ok, from} = Shop.create_product(with_display(%{"en" => "per hour"}, true))

      # An exact, chosen amount must not be advertised as "From".
      assert PriceDisplay.render(from, nil, :selected,
               amount: Decimal.new("60.00"),
               language: "en"
             ) == "$60.00 per hour"

      # Cart/order render the unit the LINE stored, not the live product's.
      assert PriceDisplay.render(nil, nil, :cart,
               amount: Decimal.new("60.00"),
               unit: "per session"
             ) == "$60.00 per session"

      # An explicit nil unit means the line stored none - it must not fall
      # back to the live product.
      assert PriceDisplay.render(from, nil, :order,
               amount: Decimal.new("60.00"),
               unit: nil
             ) == "$60.00"
    end

    test "an option range implies From even without the flag" do
      {:ok, product} =
        Shop.create_product(
          product_attrs(%{
            "metadata" => %{
              "_option_values" => %{"size" => ["S", "L"]},
              "_price_modifiers" => %{"size" => %{"L" => "10.00"}}
            }
          })
        )

      rendered = PriceDisplay.render(product, nil, :catalog, language: "en")
      assert rendered =~ "From"
      assert rendered =~ "$40.00"
    end
  end

  describe "settings survive the paths that used to erase them" do
    test "a CSV re-import preserves the admin's unit" do
      {:ok, product} =
        Shop.create_product(with_display(%{"en" => "per hour"}, true))

      slug = product.slug[lang()]

      # The importer rebuilds metadata from the feed and knows nothing
      # about display settings.
      {:ok, updated, :updated} =
        Shop.upsert_product(%{
          "title" => %{lang() => "Consulting (updated)"},
          "slug" => %{lang() => slug},
          "price" => Decimal.new("45.00"),
          "status" => "active",
          "metadata" => %{"_option_values" => %{}}
        })

      assert %{unit: %{"en" => "per hour"}, from: true} = PriceDisplay.settings(updated)
    end

    test "an explicit incoming namespace still wins" do
      {:ok, product} = Shop.create_product(with_display(%{"en" => "per hour"}, true))

      {:ok, updated, :updated} =
        Shop.upsert_product(%{
          "slug" => %{lang() => product.slug[lang()]},
          "title" => %{lang() => "Consulting"},
          "price" => Decimal.new("40.00"),
          "metadata" => %{@key => PriceDisplay.build(%{"en" => "per day"}, false)}
        })

      assert %{unit: %{"en" => "per day"}, from: false} = PriceDisplay.settings(updated)
    end
  end

  describe "cart snapshot" do
    test "the line stores the unit resolved in the visitor's language" do
      {:ok, product} =
        Shop.create_product(
          with_display(%{"en" => "per hour", "ru" => "в час"}, false)
          |> Map.put("requires_shipping", false)
        )

      {:ok, cart} = Shop.create_cart(session_id: "pd-#{System.unique_integer([:positive])}")
      {:ok, cart} = Shop.add_to_cart(cart, product, 1, language: "ru")

      [item] = cart.items
      assert item.metadata["price_unit"] == "в час"
    end

    test "a product without a unit stores none" do
      {:ok, product} = Shop.create_product(product_attrs(%{"requires_shipping" => false}))

      {:ok, cart} = Shop.create_cart(session_id: "pd-#{System.unique_integer([:positive])}")
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)

      [item] = cart.items
      refute Map.has_key?(item.metadata || %{}, "price_unit")
    end

    test "the unit rides into the order's line items" do
      {:ok, product} =
        Shop.create_product(
          with_display(%{"en" => "per hour"}, false)
          |> Map.put("requires_shipping", false)
        )

      {:ok, cart} = Shop.create_cart(session_id: "pd-#{System.unique_integer([:positive])}")
      {:ok, cart} = Shop.add_to_cart(cart, product, 2, language: "en")

      {:ok, order} =
        Shop.convert_cart_to_order(cart,
          billing_data: %{
            "email" => "pd-#{System.unique_integer([:positive])}@example.com",
            "country" => "US"
          }
        )

      line = Enum.find(order.line_items, &(&1["type"] == "product"))
      assert line["price_unit"] == "per hour"
    end
  end

  describe "order pages render the snapshot shape" do
    test "the billing helpers all accept a snapshot MAP, not just a profile struct" do
      # Order pages now prefer order.billing_snapshot, which is a plain map.
      # Every helper the confirmation template calls on it must handle that
      # shape: profile_email/1 did not, and the page 500'd AFTER the order
      # had been created - the customer's money was taken and their receipt
      # was an error page. Caught by driving a real checkout in the browser;
      # no unit test rendered the template.
      alias PhoenixKitEcommerce.Web.Helpers

      snapshot = %{
        "type" => "individual",
        "first_name" => "Max",
        "last_name" => "Don",
        "email" => "max@example.com",
        "address_line1" => "1 Test Street",
        "city" => "Tallinn",
        "postal_code" => "10111",
        "country" => "EE"
      }

      assert Helpers.profile_display_name(snapshot) == "Max Don"
      assert Helpers.profile_email(snapshot) == "max@example.com"
      assert Helpers.profile_address(snapshot) =~ "Tallinn"

      # A company snapshot resolves its name, and a sparse one does not raise.
      assert Helpers.profile_display_name(%{"type" => "company", "company_name" => "ACME"}) ==
               "ACME"

      assert Helpers.profile_email(%{}) == nil
      assert Helpers.profile_address(%{}) == ""
    end
  end
end
