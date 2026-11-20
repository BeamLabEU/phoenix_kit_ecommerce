defmodule PhoenixKitEcommerce.BaseCurrencyRepriceCatalogueTest do
  @moduledoc """
  `PhoenixKitEcommerce.reprice_for_base_change/3`'s CATALOGUE leg — the
  counterpart to `base_currency_reprice_test.exs`'s legacy suite (see that
  function's moduledoc, "Product source scope").

  Needs `phoenix_kit_catalogue` loaded (with its own migrations applied to
  the test DB) — excluded via `test_helper.exs`'s `catalogue_exclude`
  whenever the optional dependency isn't present, same as
  `cart_catalogue_test.exs`/`catalogue_view_test.exs`. `async: false`:
  flips the process-wide `shop_product_source` config key.

  Money model pinned here (see the function's docs for the full picture):
  the item's own `base_price` column; `data["ecommerce"]["compare_at_price"]`/
  `["cost_per_item"]` (decimal strings or JSON numbers, read the way the
  storefront view reads them); `data["ecommerce"]["currency"]` as the label;
  `data["ecommerce"]["shopify"]["price_fit"]`'s money fields; item-level
  `data["ecommerce"]["price_modifiers"]` (`option_key -> value_slug -> amount`,
  no per-value type tag). A modifier's FIXED-vs-percent split comes from the
  merged global + category option schema, but only for PRICE-AFFECTING
  options; every other key (an attribute-set key, an option that does not
  affect price) is a discovered option, which the storefront prices as fixed,
  so it is repriced as fixed. `markup_percentage`/`discount_percentage` are
  percentages, currency-free by construction, and are never touched.

  Everything is scoped to the shop's own catalogue (`shop_catalogue`); another
  catalogue's rows are left byte-for-byte alone.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  # Quiets the compiler's static xref check for `mix test` runs where the
  # optional `phoenix_kit_catalogue` dependency isn't declared — every test
  # in this module is excluded in that case (see `test_helper.exs`), so the
  # calls below are never actually reached.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.APIFixtures
  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ShopConfig

  import PhoenixKitEcommerce.CartApiFixtures, only: [after_first_query: 3]

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    on_exit(fn -> Currency.put_request_currency(nil) end)

    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, _usd} =
      Billing.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _eur} =
      Billing.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    :ok
  end

  # No `PhoenixKitEcommerce.update_config/2` exists yet — writes the
  # `phoenix_kit_shop_config` row directly, same as `cart_catalogue_test.exs`.
  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  defp billing_data(n) do
    %{
      "email" => "reprice-cat-#{n}@example.com",
      "first_name" => "Test",
      "last_name" => "Buyer",
      "address_line1" => "1 Test Street",
      "city" => "Testville",
      "postal_code" => "10001",
      "country" => "US"
    }
  end

  defp money_snapshot_cart(cart_uuid) do
    cart = Shop.get_cart!(cart_uuid)

    %{
      currency: cart.currency,
      base_currency: cart.base_currency,
      exchange_rate: cart.exchange_rate,
      subtotal: cart.subtotal,
      shipping_amount: cart.shipping_amount,
      tax_amount: cart.tax_amount,
      discount_amount: cart.discount_amount,
      total: cart.total,
      items:
        cart.items
        |> Enum.sort_by(& &1.uuid)
        |> Enum.map(fn item ->
          %{
            uuid: item.uuid,
            unit_price: item.unit_price,
            compare_at_price: item.compare_at_price,
            base_unit_price: item.base_unit_price,
            currency: item.currency,
            line_total: item.line_total
          }
        end)
    }
  end

  defp money_snapshot_order(order_uuid) do
    order = Billing.get_order_by_uuid(order_uuid)

    %{
      currency: order.currency,
      base_currency: order.base_currency,
      exchange_rate: order.exchange_rate,
      subtotal: order.subtotal,
      tax_amount: order.tax_amount,
      tax_rate: order.tax_rate,
      discount_amount: order.discount_amount,
      total: order.total,
      base_total: order.base_total,
      line_items: order.line_items
    }
  end

  test "reprices a catalogue item and its category's fixed modifiers; leaves the percentage, sibling data, carts and orders alone" do
    n = System.unique_integer([:positive])

    {:ok, cat} = PhoenixKitEcommerce.APIFixtures.create_shop_catalogue()

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Vases #{n}",
        catalogue_uuid: cat.uuid,
        data: %{
          "ecommerce" => %{
            "option_schema" => [
              %{
                "key" => "material",
                "label" => "Material",
                "type" => "select",
                "options" => ["PLA", "PETG"],
                "affects_price" => true,
                "modifier_type" => "fixed",
                "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}
              },
              %{
                "key" => "finish",
                "label" => "Finish",
                "type" => "select",
                "options" => ["Standard", "Premium"],
                "affects_price" => true,
                "modifier_type" => "percent",
                "price_modifiers" => %{"Standard" => "0", "Premium" => "20"}
              }
            ]
          }
        }
      })

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: cat.uuid,
        category_uuid: category.uuid,
        name: "Vase #{n}",
        base_price: Decimal.new("138.00"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "currency" => "USD",
            "compare_at_price" => "180.00",
            "vendor" => "Acme",
            "tags" => ["vase", "ceramic"],
            "shopify" => %{"handle" => "vase-#{n}", "product_id" => "123"},
            # A fixed override on "material" (schema type "fixed") and a
            # percent override on "finish" (schema type "percent") — the
            # exact "both a fixed and a percentage modifier" fixture, and
            # the same numbers `base_currency_reprice_test.exs`'s legacy
            # suite pins for the identical fixed amount.
            "price_modifiers" => %{
              "material" => %{"petg" => "10.00"},
              "finish" => %{"premium" => "20"}
            }
          }
        }
      })

    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Flat#{n}",
        "price" => Decimal.new("10.00"),
        "active" => true
      })

    product = CatalogueSource.get_product(item.uuid, [])

    # A non-empty cart, left ACTIVE across the switch.
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "reprice-cat-cart-#{n}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")
    Currency.put_request_currency(nil)

    cart_before = money_snapshot_cart(cart.uuid)
    assert cart_before.items != []

    # A second cart, converted to an order BEFORE the switch.
    Currency.put_request_currency("EUR")
    {:ok, order_cart} = Shop.create_cart(session_id: "reprice-cat-order-#{n}")
    {:ok, order_cart} = Shop.add_to_cart(order_cart, product, 1)
    {:ok, order_cart} = Shop.set_cart_shipping(order_cart, method, "US")
    Currency.put_request_currency(nil)

    {:ok, order} = Shop.convert_cart_to_order(order_cart, billing_data: billing_data(n))
    order_before = money_snapshot_order(order.uuid)

    # -- the operation under test --
    assert {:ok,
            %{
              shipping_methods: shipping_methods,
              catalogue_items: catalogue_items,
              catalogue_category_modifiers: catalogue_category_modifiers,
              catalogue_item_modifiers: catalogue_item_modifiers
            }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    assert shipping_methods == 1
    assert catalogue_items == 1
    # "material" is fixed: both its entries ("PLA" => "0", "PETG" =>
    # "10.00") are touched = 2. "finish" is percent and contributes 0.
    assert catalogue_category_modifiers == 2
    # Only the item's "material" override is fixed; "finish" is percent.
    assert catalogue_item_modifiers == 1

    reloaded_item = Catalogue.get_item!(item.uuid)
    assert Decimal.equal?(reloaded_item.base_price, Decimal.new("125.45"))

    ecommerce = reloaded_item.data["ecommerce"]
    assert Decimal.equal?(Decimal.new(ecommerce["compare_at_price"]), Decimal.new("163.64"))
    assert ecommerce["currency"] == "EUR"

    assert Decimal.equal?(
             Decimal.new(ecommerce["price_modifiers"]["material"]["petg"]),
             Decimal.new("9.09")
           )

    # Percent entry: byte-identical, not merely numerically unchanged.
    assert ecommerce["price_modifiers"]["finish"]["premium"] == "20"

    # Every sibling key in data["ecommerce"] survives the merge untouched.
    assert ecommerce["shop_status"] == "active"
    assert ecommerce["vendor"] == "Acme"
    assert ecommerce["tags"] == ["vase", "ceramic"]
    assert ecommerce["shopify"] == %{"handle" => "vase-#{n}", "product_id" => "123"}

    reloaded_category = Catalogue.get_category!(category.uuid)
    [material, finish] = reloaded_category.data["ecommerce"]["option_schema"]

    assert Decimal.equal?(Decimal.new(material["price_modifiers"]["PLA"]), Decimal.new("0"))

    assert Decimal.equal?(
             Decimal.new(material["price_modifiers"]["PETG"]),
             Decimal.new("9.09")
           )

    assert finish["modifier_type"] == "percent"
    assert finish["price_modifiers"]["Premium"] == "20"
    assert finish["price_modifiers"]["Standard"] == "0"

    reloaded_method = Shop.get_shipping_method!(method.uuid)
    assert Decimal.equal?(reloaded_method.price, Decimal.new("9.09"))

    # Carts and orders: untouched, in EVERY money field, not spot-checked.
    assert money_snapshot_cart(cart.uuid) == cart_before
    assert money_snapshot_order(order.uuid) == order_before
  end

  test "refuses when a catalogue item's explicit override type disagrees with its category's schema" do
    n = System.unique_integer([:positive])

    {:ok, cat} = PhoenixKitEcommerce.APIFixtures.create_shop_catalogue()

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Ambiguous #{n}",
        catalogue_uuid: cat.uuid,
        data: %{
          "ecommerce" => %{
            "option_schema" => [
              %{
                "key" => "material",
                "label" => "Material",
                "type" => "select",
                "options" => ["PLA", "PETG"],
                "affects_price" => true,
                "modifier_type" => "fixed",
                "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}
              }
            ]
          }
        }
      })

    # "material" is schema `modifier_type: "fixed"`; this item's override
    # explicitly claims "percent" for the same key — exactly the
    # disagreement the pre-flight guard exists to catch, catalogue-shaped.
    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: cat.uuid,
        category_uuid: category.uuid,
        name: "Ambiguous Vase #{n}",
        base_price: Decimal.new("60.00"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "currency" => "USD",
            "price_modifiers" => %{
              "material" => %{"petg" => %{"type" => "percent", "value" => "5"}}
            }
          }
        }
      })

    item_before = Catalogue.get_item!(item.uuid)
    category_before = Catalogue.get_category!(category.uuid)

    assert {:error, {:ambiguous_modifier_overrides, mismatches}} =
             Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    assert mismatches == [
             %{
               item_uuid: item.uuid,
               option_key: "material",
               stored_type: "percent",
               schema_type: "fixed"
             }
           ]

    # Nothing written anywhere — the whole operation refused up front.
    assert Catalogue.get_item!(item.uuid) == item_before
    assert Catalogue.get_category!(category.uuid) == category_before
  end

  test "reprices a category's own fixed option-schema modifiers even with no items in it, leaving its percentage alone" do
    n = System.unique_integer([:positive])

    {:ok, cat} = PhoenixKitEcommerce.APIFixtures.create_shop_catalogue()

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Empty Category #{n}",
        catalogue_uuid: cat.uuid,
        data: %{
          "ecommerce" => %{
            "option_schema" => [
              %{
                "key" => "material",
                "label" => "Material",
                "type" => "select",
                "options" => ["PLA", "PETG"],
                "affects_price" => true,
                "modifier_type" => "fixed",
                "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}
              },
              %{
                "key" => "finish",
                "label" => "Finish",
                "type" => "select",
                "options" => ["Standard", "Premium"],
                "affects_price" => true,
                "modifier_type" => "percent",
                "price_modifiers" => %{"Standard" => "0", "Premium" => "20"}
              }
            ]
          }
        }
      })

    assert {:ok,
            %{
              catalogue_items: 0,
              catalogue_category_modifiers: catalogue_category_modifiers
            }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    # "material" (fixed, 2 entries: PLA/PETG). "finish" is percent and
    # contributes 0. Reached purely by listing categories, not through any
    # item — proves the category leg doesn't depend on having items.
    assert catalogue_category_modifiers == 2

    reloaded_category = Catalogue.get_category!(category.uuid)
    [material, finish] = reloaded_category.data["ecommerce"]["option_schema"]

    assert Decimal.equal?(Decimal.new(material["price_modifiers"]["PLA"]), Decimal.new("0"))

    assert Decimal.equal?(
             Decimal.new(material["price_modifiers"]["PETG"]),
             Decimal.new("9.09")
           )

    assert finish["modifier_type"] == "percent"
    assert finish["price_modifiers"]["Premium"] == "20"
    assert finish["price_modifiers"]["Standard"] == "0"
  end

  test "reprices an item with no category without crashing; price_modifiers resolve only against the global schema" do
    n = System.unique_integer([:positive])

    {:ok, _} =
      Options.update_global_options([
        %{
          "key" => "material",
          "label" => "Material",
          "type" => "select",
          "options" => ["PLA", "PETG"],
          "affects_price" => true,
          "modifier_type" => "fixed",
          "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}
        }
      ])

    {:ok, cat} = PhoenixKitEcommerce.APIFixtures.create_shop_catalogue()

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: cat.uuid,
        name: "Uncategorized Vase #{n}",
        base_price: Decimal.new("50.00"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "currency" => "USD",
            "price_modifiers" => %{
              # Resolves via the GLOBAL schema — there is no category to
              # check at all.
              "material" => %{"petg" => "10.00"},
              # Named by no schema: the storefront prices such a key as a
              # fixed amount (a discovered option), so it is repriced as one.
              # This is the SAME code path a categorized item's unmatched
              # key takes, reached via a `nil` category.
              "size" => %{"large" => "7.00"}
            }
          }
        }
      })

    assert item.category_uuid == nil

    assert {:ok,
            %{
              catalogue_items: 1,
              catalogue_item_modifiers: catalogue_item_modifiers
            }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    assert catalogue_item_modifiers == 2

    reloaded_item = Catalogue.get_item!(item.uuid)
    assert Decimal.equal?(reloaded_item.base_price, Decimal.new("45.45"))

    ecommerce = reloaded_item.data["ecommerce"]
    assert ecommerce["currency"] == "EUR"

    assert Decimal.equal?(
             Decimal.new(ecommerce["price_modifiers"]["material"]["petg"]),
             Decimal.new("9.09")
           )

    assert ecommerce["price_modifiers"]["size"]["large"] == "6.36"
  end

  test "reprices a trashed item, invisible to Catalogue.list_items/1" do
    n = System.unique_integer([:positive])

    {:ok, cat} = PhoenixKitEcommerce.APIFixtures.create_shop_catalogue()

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: cat.uuid,
        name: "Trashed Vase #{n}",
        base_price: Decimal.new("90.00"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "currency" => "USD",
            "price_modifiers" => %{"material" => %{"petg" => "22.00"}}
          }
        }
      })

    {:ok, trashed} = Catalogue.trash_item(item)
    assert trashed.status == "deleted"

    # Confirms the gap this test closes: the public helper genuinely
    # cannot see this row.
    assert Catalogue.list_items() == []

    assert {:ok,
            %{
              catalogue_items: 1,
              catalogue_item_modifiers: catalogue_item_modifiers
            }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    # No category and no schema names "material": repriced as fixed, the
    # way the storefront prices a key it discovers on the item.
    assert catalogue_item_modifiers == 1

    reloaded_item = Catalogue.get_item!(item.uuid)
    assert reloaded_item.status == "deleted"
    assert Decimal.equal?(reloaded_item.base_price, Decimal.new("81.82"))
    assert reloaded_item.data["ecommerce"]["currency"] == "EUR"
    assert reloaded_item.data["ecommerce"]["price_modifiers"]["material"]["petg"] == "20.00"
  end

  test "reprices an item under a trashed category (and the category's own fixed defaults), invisible to the public list functions" do
    n = System.unique_integer([:positive])

    {:ok, cat} = PhoenixKitEcommerce.APIFixtures.create_shop_catalogue()

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Trashed Category #{n}",
        catalogue_uuid: cat.uuid,
        data: %{
          "ecommerce" => %{
            "option_schema" => [
              %{
                "key" => "material",
                "label" => "Material",
                "type" => "select",
                "options" => ["PLA", "PETG"],
                "affects_price" => true,
                "modifier_type" => "fixed",
                "price_modifiers" => %{"PLA" => "0", "PETG" => "8.00"}
              },
              %{
                "key" => "finish",
                "label" => "Finish",
                "type" => "select",
                "options" => ["Standard", "Premium"],
                "affects_price" => true,
                "modifier_type" => "percent",
                "price_modifiers" => %{"Standard" => "0", "Premium" => "15"}
              }
            ]
          }
        }
      })

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: cat.uuid,
        category_uuid: category.uuid,
        name: "Item Under Trashed Category #{n}",
        base_price: Decimal.new("44.00"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "currency" => "USD",
            "price_modifiers" => %{
              "material" => %{"petg" => "8.00"},
              "finish" => %{"premium" => "15"}
            }
          }
        }
      })

    # Default disposition (`:cascade`): trashing the category also
    # trashes its items.
    {:ok, trashed_category} = Catalogue.trash_category(category)
    assert trashed_category.status == "deleted"
    assert Catalogue.get_item!(item.uuid).status == "deleted"

    # Confirms the gap: both public helpers genuinely cannot see these
    # rows once the category is trashed.
    assert Catalogue.list_items() == []
    assert Catalogue.list_categories_for_catalogue(cat.uuid) == []

    assert {:ok,
            %{
              catalogue_items: 1,
              catalogue_item_modifiers: catalogue_item_modifiers,
              catalogue_category_modifiers: catalogue_category_modifiers
            }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    # Item's "material" override (fixed, via the trashed category's own
    # schema — still resolvable, the category row still exists).
    assert catalogue_item_modifiers == 1
    # Category's own "material" defaults (PLA/PETG, fixed) = 2; "finish"
    # is percent and contributes 0.
    assert catalogue_category_modifiers == 2

    reloaded_item = Catalogue.get_item!(item.uuid)
    assert reloaded_item.status == "deleted"
    assert Decimal.equal?(reloaded_item.base_price, Decimal.new("40.00"))
    assert reloaded_item.data["ecommerce"]["currency"] == "EUR"

    assert Decimal.equal?(
             Decimal.new(reloaded_item.data["ecommerce"]["price_modifiers"]["material"]["petg"]),
             Decimal.new("7.27")
           )

    # Percent entry: byte-identical, not repriced.
    assert reloaded_item.data["ecommerce"]["price_modifiers"]["finish"]["premium"] == "15"

    reloaded_category = Catalogue.get_category!(category.uuid)
    assert reloaded_category.status == "deleted"
    [material, finish] = reloaded_category.data["ecommerce"]["option_schema"]

    assert Decimal.equal?(Decimal.new(material["price_modifiers"]["PLA"]), Decimal.new("0"))

    assert Decimal.equal?(
             Decimal.new(material["price_modifiers"]["PETG"]),
             Decimal.new("7.27")
           )

    assert finish["modifier_type"] == "percent"
    assert finish["price_modifiers"]["Premium"] == "15"
  end

  # The repair for a shop whose base was switched without this operation:
  # prices are already meant in the new base, only the labels are stale, and
  # with `shop_enforce_product_currency` on the cart refuses every item.
  test "a multiplier of 1 relabels without changing a price, and the enforced cart accepts the item again" do
    import Ecto.Query

    n = System.unique_integer([:positive])

    Repo.update_all(from(c in Currency, where: c.code == "USD"),
      set: [is_default: false, exchange_rate: Decimal.new("1.1")]
    )

    Repo.update_all(from(c in Currency, where: c.code == "EUR"),
      set: [is_default: true, exchange_rate: Decimal.new("1.0")]
    )

    PhoenixKit.Cache.clear(:billing_currencies)
    assert Billing.get_base_currency().code == "EUR"

    PhoenixKit.Settings.update_boolean_setting_with_module(
      "shop_enforce_product_currency",
      true,
      "shop"
    )

    PhoenixKit.Cache.invalidate(:settings, "shop_enforce_product_currency")

    on_exit(fn ->
      PhoenixKit.Settings.update_boolean_setting_with_module(
        "shop_enforce_product_currency",
        false,
        "shop"
      )

      PhoenixKit.Cache.invalidate(:settings, "shop_enforce_product_currency")
    end)

    {:ok, cat} = PhoenixKitEcommerce.APIFixtures.create_shop_catalogue()

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: cat.uuid,
        name: "Planter #{n}",
        base_price: Decimal.new("19.80"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "currency" => "USD",
            "compare_at_price" => "25.00",
            "price_modifiers" => %{"size" => %{"5-inches" => "9.00"}}
          }
        }
      })

    {:ok, cart} = Shop.create_cart(session_id: "relabel-#{n}")

    assert {:error, :currency_mismatch} =
             Shop.add_to_cart(cart, CatalogueSource.get_product(item.uuid, []), 1)

    assert {:ok, %{catalogue_items: 1}} =
             Shop.reprice_for_base_change("USD", "EUR", Decimal.new(1))

    reloaded = Catalogue.get_item!(item.uuid)
    ecommerce = reloaded.data["ecommerce"]

    assert ecommerce["currency"] == "EUR"
    assert Decimal.equal?(reloaded.base_price, Decimal.new("19.80"))
    assert Decimal.equal?(Decimal.new(ecommerce["compare_at_price"]), Decimal.new("25.00"))

    assert Decimal.equal?(
             Decimal.new(ecommerce["price_modifiers"]["size"]["5-inches"]),
             Decimal.new("9.00")
           )

    assert {:ok, _cart} =
             Shop.add_to_cart(cart, CatalogueSource.get_product(item.uuid, []), 1)
  end

  defp material_schema(price_modifiers \\ %{"PLA" => "0", "PETG" => "10.00"}) do
    %{
      "key" => "material",
      "label" => "Material",
      "type" => "select",
      "options" => ["PLA", "PETG"],
      "affects_price" => true,
      "modifier_type" => "fixed",
      "price_modifiers" => price_modifiers
    }
  end

  defp create_item!(catalogue, attrs, ecommerce) do
    n = System.unique_integer([:positive])

    {:ok, item} =
      Catalogue.create_item(
        Map.merge(
          %{
            catalogue_uuid: catalogue.uuid,
            name: "Item #{n}",
            base_price: Decimal.new("50.00"),
            status: "active",
            data: %{"ecommerce" => Map.merge(%{"shop_status" => "active"}, ecommerce)}
          },
          attrs
        )
      )

    item
  end

  # The row-lock statements (`FOR UPDATE` / `FOR SHARE`) the code under test
  # runs in this process, in order: `{table, mode, [uuid, ...]}` where the
  # uuids are the statement's parameters.
  #
  # The catalogue's advisory lock (`pg_advisory_xact_lock(class, hashtext(uuid))`)
  # shows up as `{"advisory", "catalogue", [catalogue_uuid]}`.
  defp lock_trace(fun) do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        mode = Enum.find(["FOR UPDATE", "FOR SHARE"], &String.ends_with?(meta.query, &1))

        cond do
          self() != test ->
            :ok

          mode ->
            send(test, {:lock, {meta.source, mode, uuid_params(meta.params)}})

          meta.query =~ "pg_advisory_xact_lock($1::int, hashtext($2::text))" ->
            send(test, {:lock, {"advisory", "catalogue", [List.last(meta.params)]}})

          true ->
            :ok
        end
      end,
      nil
    )

    try do
      assert {:ok, _} = fun.()
    after
      :telemetry.detach(id)
    end

    drain_locks([])
  end

  defp uuid_params(params) do
    params
    |> List.flatten()
    |> Enum.flat_map(fn
      <<_::128>> = raw -> [Ecto.UUID.load!(raw)]
      _ -> []
    end)
  end

  defp drain_locks(acc) do
    receive do
      {:lock, entry} -> drain_locks([entry | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ecommerce_of(item_uuid), do: Catalogue.get_item!(item_uuid).data["ecommerce"]

  # The uuids of the catalogue items UPDATEd by `fun`, one list per statement,
  # next to what `fun` returned. Shows that a write really was made before
  # the failure a rollback test provokes.
  defp item_updates(fun) do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test and meta.source == "phoenix_kit_cat_items" and
             String.starts_with?(meta.query, "UPDATE"),
           do: send(test, {:item_update, uuid_params(meta.params)})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(id)
      end

    {result, drain_item_updates([])}
  end

  defp drain_item_updates(acc) do
    receive do
      {:item_update, uuids} -> drain_item_updates([uuids | acc])
    after
      0 -> acc |> Enum.reverse() |> List.flatten()
    end
  end

  # Two items of the shop in the order the pass handles them (uuid order):
  # the first is written before the second one's write is attempted.
  defp earlier_and_later_item!(shop, ecommerce) do
    [earlier, later] =
      Enum.sort_by(
        for(_ <- 1..2, do: create_item!(shop, %{base_price: Decimal.new("100.00")}, ecommerce)),
        & &1.uuid
      )

    {earlier, later}
  end

  defp rebuild_jobs do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == "PhoenixKitEcommerce.Workers.SearchRebuildWorker",
        select: %{args: j.args, state: j.state}
      )
    )
  end

  describe "scope" do
    test "leaves a catalogue other than the shop's byte-for-byte untouched" do
      n = System.unique_integer([:positive])
      {:ok, shop} = APIFixtures.create_shop_catalogue()
      other = APIFixtures.other_catalogue!()

      {:ok, other_category} =
        Catalogue.create_category(%{
          name: "Other #{n}",
          catalogue_uuid: other.uuid,
          data: %{"ecommerce" => %{"option_schema" => [material_schema()]}}
        })

      other_item =
        create_item!(
          other,
          %{category_uuid: other_category.uuid, base_price: Decimal.new("33.00")},
          %{
            "currency" => "USD",
            "compare_at_price" => "40.00",
            "price_modifiers" => %{"material" => %{"petg" => "10.00"}}
          }
        )

      shop_item = create_item!(shop, %{base_price: Decimal.new("100.00")}, %{"currency" => "USD"})

      item_before = Catalogue.get_item!(other_item.uuid)
      category_before = Catalogue.get_category!(other_category.uuid)

      assert {:ok, %{catalogue_items: 1, catalogue_category_modifiers: 0}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      assert Catalogue.get_item!(other_item.uuid) == item_before
      assert Catalogue.get_category!(other_category.uuid) == category_before

      assert Decimal.equal?(Catalogue.get_item!(shop_item.uuid).base_price, Decimal.new("90.91"))
    end

    test "a trashed shop catalogue is still found, and its rows are repriced" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()
      item = create_item!(shop, %{base_price: Decimal.new("100.00")}, %{"currency" => "USD"})

      {:ok, _trashed} = Catalogue.trash_catalogue(shop)

      assert {:ok, %{catalogue_items: 1}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      assert Decimal.equal?(Catalogue.get_item!(item.uuid).base_price, Decimal.new("90.91"))
    end

    test "refuses before any write when the catalogue source cannot resolve the shop catalogue" do
      n = System.unique_integer([:positive])
      other = APIFixtures.other_catalogue!()
      APIFixtures.put_config!("shop_catalogue", "no-such-catalogue-#{n}")

      item = create_item!(other, %{base_price: Decimal.new("33.00")}, %{"currency" => "USD"})

      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Flat#{n}", "price" => Decimal.new("10.00")})

      item_before = Catalogue.get_item!(item.uuid)

      assert Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091")) ==
               {:error, :no_shop_catalogue}

      assert Shop.base_currency_change_supported() == {:error, :no_shop_catalogue}

      assert Catalogue.get_item!(item.uuid) == item_before
      assert Decimal.equal?(Shop.get_shipping_method!(method.uuid).price, Decimal.new("10.00"))
    end

    test "the legacy source with no resolvable shop catalogue skips the catalogue pass" do
      n = System.unique_integer([:positive])
      set_product_source("legacy")
      other = APIFixtures.other_catalogue!()
      APIFixtures.put_config!("shop_catalogue", "no-such-catalogue-#{n}")

      item = create_item!(other, %{base_price: Decimal.new("33.00")}, %{"currency" => "USD"})

      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Flat#{n}", "price" => Decimal.new("10.00")})

      item_before = Catalogue.get_item!(item.uuid)

      assert {:ok, %{catalogue_items: 0, shipping_methods: 1}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      assert Shop.base_currency_change_supported() == :ok
      assert Catalogue.get_item!(item.uuid) == item_before
      assert Decimal.equal?(Shop.get_shipping_method!(method.uuid).price, Decimal.new("9.09"))
    end
  end

  describe "writes" do
    test "are attributed to the operation and logged as automatic; the catalogue stays silent and a rebuild job tells the search index" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      {:ok, category} =
        Catalogue.create_category(%{
          name: "Attributed",
          catalogue_uuid: shop.uuid,
          data: %{"ecommerce" => %{"option_schema" => [material_schema()]}}
        })

      item =
        create_item!(shop, %{category_uuid: category.uuid}, %{
          "currency" => "USD",
          "compare_at_price" => "80.00"
        })

      CataloguePubSub.subscribe()

      assert {:ok, _} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      item_entry =
        assert_activity_logged("item.updated",
          resource_uuid: item.uuid,
          metadata_has: %{"via" => "base_currency_change"}
        )

      assert item_entry.mode == "auto"
      assert inspect(item_entry.metadata["changes"]) =~ "data.ecommerce.compare_at_price"

      category_entry =
        assert_activity_logged("category.updated",
          resource_uuid: category.uuid,
          metadata_has: %{"via" => "base_currency_change"}
        )

      assert category_entry.mode == "auto"

      # The catalogue announced nothing, so the search index hears of the
      # new prices through the one rebuild job the operation queued itself.
      assert [%{args: %{}, state: "scheduled"}] = rebuild_jobs()

      # The subscription works (control), and the operation sent nothing.
      refute_received {:catalogue_data_changed, _kind, _uuid, _catalogue}
      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(item.uuid), %{name: "Renamed"})
      assert_received {:catalogue_data_changed, :item, _uuid, _catalogue}
    end

    test "are computed from the row as it is when written, not from the copy read at the start" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      item =
        create_item!(shop, %{}, %{
          "currency" => "USD",
          "vendor" => "Old vendor",
          "compare_at_price" => "100.00"
        })

      # Another writer changes the row right after the worklist was read.
      test_pid = self()
      handler_id = {:stale_row_writer, make_ref()}

      :telemetry.attach(
        handler_id,
        [:phoenix_kit_ecommerce, :test, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == test_pid and not Process.get(:stale_row_written, false) and
               query =~ ~s|."catalogue_uuid" = $1| and query =~ "phoenix_kit_cat_items" do
            Process.put(:stale_row_written, true)

            Repo.update_all(
              from(i in PhoenixKitCatalogue.Schemas.Item, where: i.uuid == ^item.uuid),
              set: [
                data: %{
                  "api" => %{"note" => "written meanwhile"},
                  "ecommerce" =>
                    Map.merge(item.data["ecommerce"], %{
                      "vendor" => "New vendor",
                      "compare_at_price" => "200.00"
                    })
                }
              ]
            )
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))
      assert Process.get(:stale_row_written)

      reloaded = Catalogue.get_item!(item.uuid)
      assert reloaded.data["api"] == %{"note" => "written meanwhile"}
      assert reloaded.data["ecommerce"]["vendor"] == "New vendor"
      assert reloaded.data["ecommerce"]["compare_at_price"] == "181.82"
    end

    test "keep a sibling data key another writer owns and change only the money paths" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      item =
        create_item!(shop, %{}, %{
          "currency" => "USD",
          "vendor" => "Acme",
          "compare_at_price" => "10.00"
        })

      {:ok, item} =
        Catalogue.update_item(item, %{data: Map.put(item.data, "api", %{"note" => "kept"})})

      assert {:ok, _} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      reloaded = Catalogue.get_item!(item.uuid)
      assert reloaded.data["api"] == %{"note" => "kept"}
      assert reloaded.data["ecommerce"]["vendor"] == "Acme"
      assert reloaded.data["ecommerce"]["compare_at_price"] == "9.09"
    end
  end

  describe "parsing" do
    test "reprices compare_at_price and cost_per_item stored as strings" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      item =
        create_item!(shop, %{}, %{
          "currency" => "USD",
          "compare_at_price" => "100.00",
          "cost_per_item" => "40.00"
        })

      assert {:ok, _} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      ecommerce = ecommerce_of(item.uuid)
      assert ecommerce["compare_at_price"] == "90.91"
      assert ecommerce["cost_per_item"] == "36.36"
    end

    test "reprices compare_at_price, cost_per_item and modifier leaves stored as JSON numbers" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      item =
        create_item!(shop, %{}, %{
          "currency" => "USD",
          "compare_at_price" => 100,
          "cost_per_item" => 40.5,
          "price_modifiers" => %{
            "size" => %{"large" => 10, "huge" => 12.5, "boxed" => %{"value" => 11}}
          }
        })

      assert {:ok, %{catalogue_item_modifiers: 3}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      ecommerce = ecommerce_of(item.uuid)
      assert ecommerce["compare_at_price"] == "90.91"
      assert ecommerce["cost_per_item"] == "36.82"
      assert ecommerce["price_modifiers"]["size"]["large"] == "9.09"
      assert ecommerce["price_modifiers"]["size"]["huge"] == "11.36"
      assert ecommerce["price_modifiers"]["size"]["boxed"] == %{"value" => "10.00"}
    end

    test "reprices the money fields of the Shopify price fit note, and nothing else in it" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      price_fit = %{
        "rule" => "never_cheaper",
        "variants" => 3,
        "over" => 2,
        "under" => 0,
        "max_over" => "10.00",
        "max_under" => "5.00",
        "base_offset" => "-2.50",
        "approximated" => true,
        "synced_at" => "2026-11-01T10:00:00Z"
      }

      item =
        create_item!(shop, %{}, %{
          "currency" => "USD",
          "shopify" => %{"handle" => "mug", "price_fit" => price_fit}
        })

      assert {:ok, _} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      shopify = ecommerce_of(item.uuid)["shopify"]
      assert shopify["handle"] == "mug"

      assert shopify["price_fit"] ==
               Map.merge(price_fit, %{
                 "max_over" => "9.09",
                 "max_under" => "4.55",
                 "base_offset" => "-2.27"
               })
    end
  end

  describe "modifier types" do
    test "a key from a non-price-affecting option is a discovered option and is repriced as fixed" do
      {:ok, _} =
        Options.update_global_options([
          %{
            "key" => "color",
            "label" => "Color",
            "type" => "select",
            "options" => ["red"],
            "affects_price" => false,
            "modifier_type" => "percent",
            "price_modifiers" => %{"red" => "5"}
          }
        ])

      {:ok, shop} = APIFixtures.create_shop_catalogue()

      item =
        create_item!(shop, %{}, %{
          "currency" => "USD",
          "price_modifiers" => %{"color" => %{"red" => "10.00"}}
        })

      assert {:ok, %{catalogue_item_modifiers: 1}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      assert ecommerce_of(item.uuid)["price_modifiers"]["color"]["red"] == "9.09"
    end

    test "an explicit override map keeps its shape, and only its value is scaled" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      {:ok, category} =
        Catalogue.create_category(%{
          name: "Shaped",
          catalogue_uuid: shop.uuid,
          data: %{"ecommerce" => %{"option_schema" => [material_schema()]}}
        })

      item =
        create_item!(shop, %{category_uuid: category.uuid}, %{
          "currency" => "USD",
          "price_modifiers" => %{
            "material" => %{"petg" => %{"type" => "fixed", "value" => "10.00"}}
          }
        })

      assert {:ok, %{catalogue_item_modifiers: 1}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      assert ecommerce_of(item.uuid)["price_modifiers"]["material"]["petg"] ==
               %{"type" => "fixed", "value" => "9.09"}
    end

    test "storefront price parity: a set-keyed surcharge times the multiplier is the new price" do
      # The catalogue app registers this same guard at boot and has no way to
      # unregister it, so there is nothing to undo afterwards.
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      {:ok, shop} = APIFixtures.create_shop_catalogue()
      {:ok, set} = AttributeSets.create_set(%{name: "Color"}, actor_uuid: Ecto.UUID.generate())

      {:ok, _red} =
        AttributeSets.create_value(set, %{label: "Red", slug: "red"},
          actor_uuid: Ecto.UUID.generate()
        )

      item =
        create_item!(shop, %{base_price: Decimal.new("20.00")}, %{
          "currency" => "USD",
          "price_modifiers" => %{"color" => %{"red" => "5.00"}}
        })

      {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
      :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, ["red"])

      selection = %{"color" => "red"}
      multiplier = Decimal.new("0.909091")

      before_product = CatalogueSource.get_product(item.uuid, [])
      assert before_product.metadata["_price_modifiers"] == %{"color" => %{"red" => "5.00"}}
      before_price = Shop.calculate_product_price(before_product, selection)
      assert Decimal.equal?(before_price, Decimal.new("25.00"))

      assert {:ok, %{catalogue_item_modifiers: 1}} =
               Shop.reprice_for_base_change("USD", "EUR", multiplier)

      after_price =
        item.uuid
        |> CatalogueSource.get_product([])
        |> Shop.calculate_product_price(selection)

      # Two roundings (base price and surcharge), half a cent each at most.
      drift =
        before_price |> Decimal.mult(multiplier) |> Decimal.sub(after_price) |> Decimal.abs()

      assert Decimal.compare(drift, Decimal.new("0.01")) in [:lt, :eq]
      assert Decimal.equal?(after_price, Decimal.new("22.73"))
    end
  end

  describe "currency labels" do
    test "an item labelled with another currency, or none, is still repriced and is counted" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      usd = create_item!(shop, %{base_price: Decimal.new("10.00")}, %{"currency" => "USD"})
      gbp = create_item!(shop, %{base_price: Decimal.new("10.00")}, %{"currency" => "GBP"})
      bare = create_item!(shop, %{base_price: Decimal.new("10.00")}, %{})

      assert {:ok, %{catalogue_items: 3, catalogue_items_relabelled_from_other: 2}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      for item <- [usd, gbp, bare] do
        reloaded = Catalogue.get_item!(item.uuid)
        assert reloaded.data["ecommerce"]["currency"] == "EUR"
        assert Decimal.equal?(reloaded.base_price, Decimal.new("9.09"))
      end
    end

    test "an item already in the new base is not counted, and a second identical run writes nothing" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      usd = create_item!(shop, %{base_price: Decimal.new("10.00")}, %{"currency" => "USD"})
      gbp = create_item!(shop, %{base_price: Decimal.new("10.00")}, %{"currency" => "GBP"})
      eur = create_item!(shop, %{base_price: Decimal.new("10.00")}, %{"currency" => "EUR"})

      assert {:ok, %{catalogue_items: 3, catalogue_items_relabelled_from_other: 1}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new(1))

      after_first = Enum.map([usd, gbp, eur], &Catalogue.get_item!(&1.uuid))
      logged = Enum.count(list_activities(), &(&1.action == "item.updated"))

      assert {:ok, %{catalogue_items: 3, catalogue_items_relabelled_from_other: 0}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new(1))

      assert Enum.map([usd, gbp, eur], &Catalogue.get_item!(&1.uuid)) == after_first
      assert Enum.count(list_activities(), &(&1.action == "item.updated")) == logged
    end

    test "an item created after the worklist was read is repriced too" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()
      first = create_item!(shop, %{base_price: Decimal.new("100.00")}, %{"currency" => "USD"})
      test = self()

      after_first_query("SELECT", "phoenix_kit_cat_items", fn ->
        late = create_item!(shop, %{base_price: Decimal.new("200.00")}, %{"currency" => "USD"})
        send(test, {:late_item, late})
      end)

      assert {:ok, %{catalogue_items: 2}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      assert_received {:late_item, late}

      assert Decimal.equal?(Catalogue.get_item!(first.uuid).base_price, Decimal.new("90.91"))
      assert Decimal.equal?(Catalogue.get_item!(late.uuid).base_price, Decimal.new("181.82"))
      assert ecommerce_of(late.uuid)["currency"] == "EUR"
    end
  end

  describe "multiplier" do
    test "of 1 leaves every stored amount exactly as it is, number or string, and changes only the label" do
      {:ok, _} =
        Options.update_global_options([material_schema(%{"PLA" => "0", "PETG" => "9.999"})])

      {:ok, shop} = APIFixtures.create_shop_catalogue()

      {:ok, category} =
        Catalogue.create_category(%{
          name: "Exact",
          catalogue_uuid: shop.uuid,
          data: %{
            "ecommerce" => %{
              "option_schema" => [
                %{material_schema(%{"PLA" => "0", "PETG" => "9.999"}) | "key" => "finish"}
              ]
            }
          }
        })

      item =
        create_item!(shop, %{category_uuid: category.uuid}, %{
          "currency" => "USD",
          "compare_at_price" => "9.999",
          "cost_per_item" => "0",
          "price_modifiers" => %{
            "size" => %{"zero" => "0", "odd" => "9.999"},
            "finish" => %{"petg" => %{"type" => "fixed", "value" => "9.999"}}
          },
          "shopify" => %{"price_fit" => %{"max_over" => "9.999", "base_offset" => "0"}}
        })

      # Amounts a catalogue writer stored as JSON numbers keep their type.
      numeric =
        create_item!(shop, %{}, %{
          "currency" => "USD",
          "compare_at_price" => 12,
          "cost_per_item" => 0.5,
          "price_modifiers" => %{
            "size" => %{
              "float" => 3.5,
              "int" => 4,
              "boxed" => %{"type" => "fixed", "value" => 3.5}
            }
          },
          "shopify" => %{"price_fit" => %{"max_over" => 7}}
        })

      plain = create_item!(shop, %{}, %{"currency" => "USD"})

      settled =
        create_item!(shop, %{}, %{
          "currency" => "EUR",
          "compare_at_price" => 12,
          "price_modifiers" => %{"size" => %{"float" => 3.5}}
        })

      global_before = Options.get_global_options()
      category_before = Catalogue.get_category!(category.uuid)
      settled_before = Catalogue.get_item!(settled.uuid)

      # Nothing was changed, so nothing is counted as changed.
      assert {:ok,
              %{
                catalogue_items: 4,
                catalogue_items_relabelled_from_other: 0,
                catalogue_item_modifiers: 0,
                catalogue_category_modifiers: 0,
                global_modifiers: 0
              }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new(1))

      ecommerce = ecommerce_of(item.uuid)
      assert ecommerce["currency"] == "EUR"
      assert ecommerce["compare_at_price"] == "9.999"
      assert ecommerce["cost_per_item"] == "0"
      assert ecommerce["price_modifiers"]["size"] == %{"zero" => "0", "odd" => "9.999"}

      assert ecommerce["price_modifiers"]["finish"] ==
               %{"petg" => %{"type" => "fixed", "value" => "9.999"}}

      assert ecommerce["shopify"]["price_fit"] == %{"max_over" => "9.999", "base_offset" => "0"}

      # `===`: a number stays the same number, not its string spelling.
      numbers = ecommerce_of(numeric.uuid)
      assert numbers["currency"] == "EUR"
      assert numbers["compare_at_price"] === 12
      assert numbers["cost_per_item"] === 0.5
      assert numbers["price_modifiers"]["size"]["float"] === 3.5
      assert numbers["price_modifiers"]["size"]["int"] === 4
      assert numbers["price_modifiers"]["size"]["boxed"] === %{"type" => "fixed", "value" => 3.5}
      assert numbers["shopify"]["price_fit"]["max_over"] === 7

      assert Options.get_global_options() == global_before
      assert Catalogue.get_category!(category.uuid) == category_before

      # Only the label moved, so only the label is logged.
      for relabelled <- [item, numeric, plain] do
        entry =
          assert_activity_logged("item.updated",
            resource_uuid: relabelled.uuid,
            metadata_has: %{"via" => "base_currency_change"}
          )

        assert Map.keys(entry.metadata["changes"]) == ["data.ecommerce.currency"]
      end

      # Already labelled with the new base: nothing to write, nothing logged.
      refute_activity_logged("item.updated", resource_uuid: settled.uuid)
      assert Catalogue.get_item!(settled.uuid) == settled_before
    end

    test "of 0 or below is refused before any write" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()
      item = create_item!(shop, %{base_price: Decimal.new("10.00")}, %{"currency" => "USD"})
      before = Catalogue.get_item!(item.uuid)

      for bad <- [Decimal.new(0), Decimal.new("-0.5")] do
        assert {:error, {:invalid_multiplier, ^bad}} =
                 Shop.reprice_for_base_change("USD", "EUR", bad)
      end

      assert Catalogue.get_item!(item.uuid) == before
    end
  end

  describe "locks" do
    test "every category is locked before any item, each kind in uuid order" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      categories =
        for n <- 1..3 do
          {:ok, category} =
            Catalogue.create_category(%{
              name: "Ordered #{n}",
              catalogue_uuid: shop.uuid,
              data: %{"ecommerce" => %{"option_schema" => [material_schema()]}}
            })

          category
        end

      items =
        for category <- categories, _ <- 1..2 do
          create_item!(shop, %{category_uuid: category.uuid}, %{"currency" => "USD"})
        end

      trace =
        lock_trace(fn -> Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091")) end)

      # A row's own write locks it again; only the first lock matters.
      update_locks =
        trace
        |> Enum.filter(&match?({_, "FOR UPDATE", _}, &1))
        |> Enum.flat_map(fn {table, _mode, uuids} -> Enum.map(uuids, &{table, &1}) end)
        |> Enum.uniq()

      {category_locks, item_locks} =
        Enum.split_while(update_locks, &match?({"phoenix_kit_cat_categories", _}, &1))

      # The category pass takes its three first, then the item pass its six,
      # and none of the categories comes back after an item.
      assert Enum.map(category_locks, &elem(&1, 1)) ==
               categories |> Enum.map(& &1.uuid) |> Enum.sort()

      assert Enum.map(item_locks, &elem(&1, 0)) |> Enum.uniq() == ["phoenix_kit_cat_items"]
      assert Enum.map(item_locks, &elem(&1, 1)) == items |> Enum.map(& &1.uuid) |> Enum.sort()
    end
  end

  describe "the search index" do
    test "a run that changed amounts queues one rebuild of the whole index" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()
      create_item!(shop, %{base_price: Decimal.new("100.00")}, %{"currency" => "USD"})
      create_item!(shop, %{base_price: Decimal.new("200.00")}, %{"currency" => "USD"})

      assert rebuild_jobs() == []

      assert {:ok, %{catalogue_items: 2}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      # One job for both items; no catalogue uuid, so it is the job billing's
      # own `currencies_changed` announcement asks for too.
      assert [%{args: %{}, state: "scheduled"}] = rebuild_jobs()
    end

    test "is queued inside the transaction: a caller that rolls back leaves no job" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()
      item = create_item!(shop, %{base_price: Decimal.new("100.00")}, %{"currency" => "USD"})
      item_before = Catalogue.get_item!(item.uuid)

      assert {:error, :undone} =
               Repo.transaction(fn ->
                 assert {:ok, _} =
                          Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

                 assert [%{args: %{}}] = rebuild_jobs()
                 Repo.rollback(:undone)
               end)

      assert rebuild_jobs() == []
      assert Catalogue.get_item!(item.uuid) == item_before
    end

    test "a relabel moves no indexed amount and queues nothing" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()
      item = create_item!(shop, %{base_price: Decimal.new("100.00")}, %{"currency" => "USD"})

      assert {:ok, %{catalogue_items: 1}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new(1))

      # The item was written (its label), the index holds no label.
      assert ecommerce_of(item.uuid)["currency"] == "EUR"
      assert rebuild_jobs() == []
    end

    test "a run that wrote no item queues nothing" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()
      create_item!(shop, %{base_price: nil}, %{"currency" => "EUR"})

      assert {:ok, %{catalogue_items: 1}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      assert rebuild_jobs() == []
    end
  end

  describe "the late pass" do
    setup do
      {:ok, _} = Options.update_global_options([material_schema()])
      {:ok, shop} = APIFixtures.create_shop_catalogue()
      first = create_item!(shop, %{base_price: Decimal.new("100.00")}, %{"currency" => "USD"})

      # Read before the hook below exists: it fires on the first item SELECT.
      first_before = Catalogue.get_item!(first.uuid)
      test = self()

      # Created after the worklist was read: only the late pass sees it, and
      # its override claims "percent" for an option the schema has as fixed.
      after_first_query("SELECT", "phoenix_kit_cat_items", fn ->
        late =
          create_item!(shop, %{}, %{
            "currency" => "USD",
            "price_modifiers" => %{
              "material" => %{"petg" => %{"type" => "percent", "value" => "5"}}
            }
          })

        send(test, {:late_item, late})
      end)

      %{first: first, first_before: first_before}
    end

    test "refuses an ambiguous override after earlier writes, and a direct call undoes them", %{
      first: first,
      first_before: first_before
    } do
      {result, updated} =
        item_updates(fn ->
          Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))
        end)

      assert_received {:late_item, late}

      assert {:error, {:ambiguous_modifier_overrides, [mismatch]}} = result
      assert mismatch.item_uuid == late.uuid
      assert {mismatch.stored_type, mismatch.schema_type} == {"percent", "fixed"}

      # The first item was written before the late pass refused...
      assert first.uuid in updated
      refute late.uuid in updated

      # ...and everything is rolled back.
      assert Catalogue.get_item!(first.uuid) == first_before
      assert rebuild_jobs() == []
    end

    test "rolls the base switch back when billing made the call", %{
      first: first,
      first_before: first_before
    } do
      {result, updated} =
        item_updates(fn ->
          Billing.change_base_currency("EUR",
            catalog_size: 2,
            reprice: &Shop.reprice_for_base_change/3
          )
        end)

      assert_received {:late_item, late}
      assert {:error, {:ambiguous_modifier_overrides, [%{item_uuid: late_uuid}]}} = result
      assert late_uuid == late.uuid
      assert first.uuid in updated

      PhoenixKit.Cache.clear(:billing_currencies)
      assert Billing.get_base_currency().code == "USD"
      assert Catalogue.get_item!(first.uuid) == first_before
      assert rebuild_jobs() == []
    end
  end

  describe "the advisory lock" do
    test "is taken on the shop catalogue before any row is locked" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      {:ok, category} =
        Catalogue.create_category(%{
          name: "Locked",
          catalogue_uuid: shop.uuid,
          data: %{"ecommerce" => %{"option_schema" => [material_schema()]}}
        })

      create_item!(shop, %{category_uuid: category.uuid}, %{"currency" => "USD"})

      trace =
        lock_trace(fn -> Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091")) end)

      assert [{"advisory", "catalogue", [shop_uuid]} | row_locks] = trace
      assert shop_uuid == shop.uuid
      assert Enum.any?(row_locks, &match?({"phoenix_kit_cat_categories", "FOR UPDATE", _}, &1))
      assert Enum.any?(row_locks, &match?({"phoenix_kit_cat_items", "FOR UPDATE", _}, &1))
      refute Enum.any?(row_locks, &match?({"advisory", _, _}, &1))
    end
  end

  describe "through PhoenixKitBilling.change_base_currency/2" do
    test "reprices the catalogue and promotes the new base in one transaction" do
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      item =
        create_item!(shop, %{base_price: Decimal.new("100.00")}, %{
          "currency" => "USD",
          "compare_at_price" => "50.00"
        })

      assert {:ok, %{old_base: "USD"}} =
               Billing.change_base_currency("EUR",
                 catalog_size: 1,
                 reprice: &Shop.reprice_for_base_change/3
               )

      reloaded = Catalogue.get_item!(item.uuid)
      assert Decimal.equal?(reloaded.base_price, Decimal.new("90.91"))
      assert reloaded.data["ecommerce"]["currency"] == "EUR"
      assert reloaded.data["ecommerce"]["compare_at_price"] == "45.45"

      PhoenixKit.Cache.clear(:billing_currencies)
      assert Billing.get_base_currency().code == "EUR"

      assert [%{args: %{}, state: "scheduled"}] = rebuild_jobs()
    end

    test "a failing item rolls back the base switch and every earlier write" do
      n = System.unique_integer([:positive])
      {:ok, _} = Options.update_global_options([material_schema()])
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Flat#{n}", "price" => Decimal.new("10.00")})

      {:ok, category} =
        Catalogue.create_category(%{
          name: "Billing",
          catalogue_uuid: shop.uuid,
          data: %{"ecommerce" => %{"option_schema" => [material_schema()]}}
        })

      {good, bad} = earlier_and_later_item!(shop, %{"currency" => "USD"})
      assert good.uuid < bad.uuid

      Repo.update_all(
        from(i in PhoenixKitCatalogue.Schemas.Item, where: i.uuid == ^bad.uuid),
        set: [base_price: Decimal.new("-1.00")]
      )

      good_before = Catalogue.get_item!(good.uuid)
      category_before = Catalogue.get_category!(category.uuid)
      global_before = Options.get_global_options()
      usd_before = Billing.get_currency_by_code("USD")
      eur_before = Billing.get_currency_by_code("EUR")

      {result, updated} =
        item_updates(fn ->
          Billing.change_base_currency("EUR",
            catalog_size: 2,
            reprice: &Shop.reprice_for_base_change/3
          )
        end)

      assert {:error, {:catalogue_item_reprice_failed, failed_uuid, _reason}} = result
      assert failed_uuid == bad.uuid

      # The good item was written before the bad one failed: the rollback
      # below undoes a real write.
      assert good.uuid in updated
      refute bad.uuid in updated
      assert rebuild_jobs() == []

      PhoenixKit.Cache.clear(:billing_currencies)
      assert Billing.get_base_currency().code == "USD"
      assert Billing.get_currency_by_code("USD") == usd_before
      assert Billing.get_currency_by_code("EUR") == eur_before

      assert Catalogue.get_item!(good.uuid) == good_before
      assert Catalogue.get_category!(category.uuid) == category_before
      assert Options.get_global_options() == global_before
      assert Decimal.equal?(Shop.get_shipping_method!(method.uuid).price, Decimal.new("10.00"))
    end
  end

  describe "a direct call" do
    test "an item whose write fails is named in the error with its changeset, and nothing is kept" do
      n = System.unique_integer([:positive])
      {:ok, _} = Options.update_global_options([material_schema()])
      {:ok, shop} = APIFixtures.create_shop_catalogue()

      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Flat#{n}", "price" => Decimal.new("10.00")})

      {:ok, category} =
        Catalogue.create_category(%{
          name: "Written first",
          catalogue_uuid: shop.uuid,
          data: %{"ecommerce" => %{"option_schema" => [material_schema()]}}
        })

      {good, bad} = earlier_and_later_item!(shop, %{"currency" => "USD"})
      assert good.uuid < bad.uuid

      # A negative price cannot be written back through the changeset.
      Repo.update_all(
        from(i in PhoenixKitCatalogue.Schemas.Item, where: i.uuid == ^bad.uuid),
        set: [base_price: Decimal.new("-1.00")]
      )

      good_before = Catalogue.get_item!(good.uuid)
      bad_before = Catalogue.get_item!(bad.uuid)
      category_before = Catalogue.get_category!(category.uuid)
      global_before = Options.get_global_options()

      {result, updated} =
        item_updates(fn ->
          Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))
        end)

      assert {:error,
              {:catalogue_item_reprice_failed, failed_uuid, %Ecto.Changeset{valid?: false}}} =
               result

      assert failed_uuid == bad.uuid

      # The good item was written before the bad one failed.
      assert good.uuid in updated
      refute bad.uuid in updated
      assert rebuild_jobs() == []
      assert Catalogue.get_item!(good.uuid) == good_before
      assert Catalogue.get_item!(bad.uuid) == bad_before

      # The category pass wrote before the item pass failed; it is undone.
      assert Catalogue.get_category!(category.uuid) == category_before
      assert Options.get_global_options() == global_before
      assert Decimal.equal?(Shop.get_shipping_method!(method.uuid).price, Decimal.new("10.00"))
    end

    test "is atomic: a failure midway leaves the rows written before it unchanged" do
      n = System.unique_integer([:positive])
      {:ok, _} = Options.update_global_options([material_schema()])
      {:ok, shop} = APIFixtures.create_shop_catalogue()
      other = APIFixtures.other_catalogue!()

      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Flat#{n}", "price" => Decimal.new("10.00")})

      item = create_item!(shop, %{base_price: Decimal.new("100.00")}, %{"currency" => "USD"})

      # The category pass is the first catalogue write. A parent in another
      # catalogue makes its own write fail validation, after the shipping
      # method and the option schema were already written.
      {:ok, foreign_parent} =
        Catalogue.create_category(%{name: "Foreign", catalogue_uuid: other.uuid})

      {:ok, broken} =
        Catalogue.create_category(%{
          name: "Broken",
          catalogue_uuid: shop.uuid,
          data: %{"ecommerce" => %{"option_schema" => [material_schema()]}}
        })

      Repo.update_all(
        from(c in PhoenixKitCatalogue.Schemas.Category, where: c.uuid == ^broken.uuid),
        set: [parent_uuid: foreign_parent.uuid]
      )

      item_before = Catalogue.get_item!(item.uuid)
      broken_before = Catalogue.get_category!(broken.uuid)
      global_before = Options.get_global_options()

      assert {:error, {:catalogue_category_reprice_failed, uuid, _reason}} =
               Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

      assert uuid == broken.uuid

      assert Catalogue.get_item!(item.uuid) == item_before
      assert Catalogue.get_category!(broken.uuid) == broken_before
      assert Options.get_global_options() == global_before
      assert Decimal.equal?(Shop.get_shipping_method!(method.uuid).price, Decimal.new("10.00"))
    end
  end
end
