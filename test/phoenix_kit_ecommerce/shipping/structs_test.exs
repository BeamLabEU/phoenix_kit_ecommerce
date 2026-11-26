defmodule PhoenixKitEcommerce.Shipping.StructsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shipping.{
    Address,
    Context,
    Destination,
    Field,
    LabelOptions,
    Locality,
    Parcel,
    PickupPoint,
    Quote,
    RateRequest,
    Service,
    ShipmentRef,
    ShipmentRequest,
    ShipmentResult,
    TrackingUpdate
  }

  alias PhoenixKitEcommerce.Shipping.Providers.{Fixed, Table}

  @modules [
    Service,
    Field,
    Locality,
    PickupPoint,
    Address,
    Destination,
    Parcel,
    RateRequest,
    Quote,
    Context,
    ShipmentRequest,
    ShipmentResult,
    ShipmentRef,
    TrackingUpdate,
    LabelOptions
  ]

  defp locality,
    do: %Locality{
      id: "city-1",
      name: "Springfield",
      region: "Poltavska",
      postcode: "36000",
      country: "UA",
      extra: %{"settlement_ref" => "abc"}
    }

  defp point,
    do: %PickupPoint{
      id: "p1",
      name: "Branch 1",
      number: "1",
      address: "Main st 1",
      postcode: "36000",
      kind: :locker,
      lat: 49.58,
      lng: 34.55,
      limits: %{
        max_weight_g: 30_000,
        max_dims_mm: [600, 400, 300],
        max_declared: Decimal.new("5000.50")
      },
      extra: %{"ref" => "r1"}
    }

  defp address,
    do: %Address{
      postcode: "36000",
      street: "Main",
      house: "5",
      apartment: "7",
      line: "Main 5/7",
      extra: %{"entrance" => "2"}
    }

  defp parcel, do: %Parcel{weight_g: 1500, length_mm: 300, width_mm: 200, height_mm: 100}

  defp samples do
    [
      %Service{
        key: "branch",
        label: "To a branch",
        destination: :pickup_point,
        lookup: :search,
        point_code_label: "Branch number",
        point_code_format: "^\\d{1,5}$"
      },
      %Service{
        key: "courier",
        label: "Courier",
        destination: :address,
        postcode_required: true,
        countries: ["PL", "UA"]
      },
      %Field{
        key: "mode",
        label: "Mode",
        type: :select,
        options: [{"One", "1"}, {"Two", "2"}],
        required: true,
        default: "1",
        help: "Pick"
      },
      locality(),
      point(),
      address(),
      %Destination{locality: locality(), pickup_point: point(), address: address()},
      parcel(),
      %RateRequest{
        service: "branch",
        origin: %{"sender_city" => %{"id" => "c1"}},
        destination: %Destination{locality: locality(), pickup_point: point()},
        parcels: [parcel(), %Parcel{weight_g: 200}],
        declared_value: Decimal.new("1200.00"),
        cod_amount: Decimal.new("1200.00"),
        currency: "UAH",
        country: "UA"
      },
      %Quote{
        amount: Decimal.new("85.50"),
        currency: "UAH",
        cod_fee: Decimal.new("20"),
        eta: %{min_days: 1, max_days: 3, date: ~D[2026-10-12]},
        source: :table,
        breakdown: %{"billable_kg" => "1.5"},
        expires_at: ~U[2026-10-09 12:00:00Z],
        note: "Estimate"
      },
      %Context{
        provider: PhoenixKitEcommerce.Shipping.Providers.Fixed,
        service: "branch",
        settings: %{"sender_city" => %{"id" => "c1"}},
        integration_uuid: "019b669c-3c9d-7256-8ed1-edbc6ae29703",
        locale: "uk",
        currency: "UAH",
        country: "UA"
      },
      %ShipmentRequest{
        order_uuid: "019b669c-3c9d-7256-8ed1-edbc6ae29704",
        reference: "ORD-2026-0001",
        service: "branch",
        country: "EE",
        destination: %Destination{locality: locality(), pickup_point: point()},
        parcels: [parcel()],
        recipient: %{
          name: "Mari Maasikas",
          company: "Kask OÜ",
          email: "mari@example.com",
          phone: "+37255551234",
          raw_phone: "5555 1234"
        },
        idempotency_key: "6f1c2a9e-4b7d-5e21-9a3c-0d8e7f6a5b4c",
        payer: :recipient,
        description: "Vase x2, Lamp",
        declared_value: Decimal.new("59.90"),
        currency: "EUR",
        cod_amount: nil,
        cod_currency: nil
      },
      %ShipmentResult{
        carrier_ref: "C-1",
        tracking_number: "CE123456789EE",
        tracking_url: "https://track.example/CE123456789EE",
        carrier_label: "Omniva",
        extra: %{"sender" => %{"phone" => "+3725000000"}}
      },
      %ShipmentRef{
        carrier_ref: "C-1",
        tracking_number: "CE123456789EE",
        service: "branch",
        extra: %{"barcode" => "123"}
      },
      %TrackingUpdate{
        tracking_number: "CE123456789EE",
        carrier_ref: "C-1",
        status: :ready_for_pickup,
        occurred_at: ~U[2026-11-25 10:00:00Z],
        description: "Arrived at the parcel machine"
      },
      %LabelOptions{format: :a6}
    ]
  end

  describe "to_map/1 and from_map/1" do
    for module <- @modules do
      test "#{inspect(module)} round-trips" do
        module = unquote(module)
        sample = Enum.find(samples(), &match?(%{__struct__: ^module}, &1))

        assert sample |> module.to_map() |> module.from_map() == sample
      end

      test "#{inspect(module)} survives a JSON round-trip" do
        module = unquote(module)
        sample = Enum.find(samples(), &match?(%{__struct__: ^module}, &1))

        decoded = sample |> module.to_map() |> Jason.encode!() |> Jason.decode!()

        assert module.from_map(decoded) == sample
      end

      test "#{inspect(module)} turns nil and garbage into nil" do
        module = unquote(module)

        assert module.from_map(nil) == nil
        assert module.from_map("garbage") == nil
        assert module.from_map(42) == nil
        assert module.from_map([1, 2]) == nil
      end

      test "#{inspect(module)} accepts an empty map" do
        module = unquote(module)
        assert %{__struct__: ^module} = module.from_map(%{})
      end
    end
  end

  describe "to_map/1 is JSON-safe" do
    test "uses string keys, strings for Decimal/atoms and ISO 8601 for dates" do
      quote_map = Enum.find(samples(), &match?(%Quote{}, &1)) |> Quote.to_map()

      assert quote_map["amount"] == "85.50"
      assert quote_map["cod_fee"] == "20"
      assert quote_map["source"] == "table"
      assert quote_map["expires_at"] == "2026-10-09T12:00:00Z"
      assert quote_map["eta"] == %{"min_days" => 1, "max_days" => 3, "date" => "2026-10-12"}
      assert quote_map["breakdown"] == %{"billable_kg" => "1.5"}
      assert Enum.all?(Map.keys(quote_map), &is_binary/1)
    end

    test "serialises nested structs and limits" do
      map = PickupPoint.to_map(point())

      assert map["kind"] == "locker"

      assert map["limits"] == %{
               "max_weight_g" => 30_000,
               "max_dims_mm" => [600, 400, 300],
               "max_declared" => "5000.50"
             }

      request = RateRequest.to_map(Enum.find(samples(), &match?(%RateRequest{}, &1)))
      assert request["destination"]["locality"]["id"] == "city-1"
      assert [%{"weight_g" => 1500}, %{"weight_g" => 200}] = request["parcels"]
      assert request["declared_value"] == "1200.00"
    end

    test "serialises atoms inside extra" do
      map = Locality.to_map(%Locality{id: "1", extra: %{ref: :abc, nested: %{list: [:a, 1]}}})
      assert map["extra"] == %{"ref" => "abc", "nested" => %{"list" => ["a", 1]}}
    end
  end

  describe "from_map/1 is tolerant" do
    test "reads atom keys" do
      assert %Locality{id: "7", name: "Kyiv"} = Locality.from_map(%{id: 7, name: "Kyiv"})
    end

    test "unknown enum values fall back to the default" do
      assert %Service{destination: :none, lookup: :manual} =
               Service.from_map(%{"destination" => "teleport", "lookup" => "magic"})

      assert %PickupPoint{kind: :other} = PickupPoint.from_map(%{"kind" => "spaceport"})
      assert %Field{type: :string} = Field.from_map(%{"type" => "rainbow"})
      assert %Quote{source: :api} = Quote.from_map(%{"source" => "oracle"})
    end

    test "a service does not require the postcode unless it says so" do
      assert %Service{postcode_required: false} = %Service{}
      assert %Service{postcode_required: false} = Service.from_map(%{"key" => "x"})

      assert %Service{postcode_required: false} =
               Service.from_map(%{"postcode_required" => "yes"})

      assert %Service{postcode_required: true} = Service.from_map(%{"postcode_required" => true})
      assert %Service{postcode_required: true} = Service.from_map(%{postcode_required: "true"})

      assert Service.to_map(%Service{postcode_required: true})["postcode_required"] == true
    end

    test "unparseable numbers become nil or the default" do
      assert %Parcel{weight_g: 0, length_mm: nil} =
               Parcel.from_map(%{"weight_g" => "heavy", "length_mm" => "long"})

      assert %Quote{amount: nil, expires_at: nil, eta: nil} =
               Quote.from_map(%{"amount" => "free", "expires_at" => "tomorrow", "eta" => "soon"})
    end

    test "parses numeric strings and decimal commas" do
      assert %Parcel{weight_g: 1500, length_mm: 300} =
               Parcel.from_map(%{"weight_g" => "1500", "length_mm" => 300.4})

      assert %Quote{amount: amount} = Quote.from_map(%{"amount" => "85,50"})
      assert Decimal.equal?(amount, "85.50")
    end

    test "limits are completed, ordered and cleaned" do
      assert %PickupPoint{limits: limits} =
               PickupPoint.from_map(%{"limits" => %{"max_dims_mm" => [100, 600, 300]}})

      assert limits == %{max_weight_g: nil, max_dims_mm: [600, 300, 100], max_declared: nil}

      assert %PickupPoint{limits: %{max_dims_mm: nil}} =
               PickupPoint.from_map(%{"limits" => %{"max_dims_mm" => [100, 200]}})

      assert %PickupPoint{limits: %{max_weight_g: nil, max_declared: nil}} =
               PickupPoint.from_map(%{"limits" => "none"})
    end

    test "field options accept tuples, pairs and maps" do
      field =
        Field.from_map(%{
          "options" => [{"A", "a"}, ["B", "b"], %{"label" => "C", "value" => "c"}, "junk"]
        })

      assert field.options == [{"A", "a"}, {"B", "b"}, {"C", "c"}]
    end

    test "request defaults" do
      request = RateRequest.from_map(%{})

      assert request.destination == %Destination{}
      assert request.parcels == []
      assert Decimal.equal?(request.declared_value, 0)
      assert request.cod_amount == nil
    end

    test "garbage in nested lists is dropped" do
      request = RateRequest.from_map(%{"parcels" => [%{"weight_g" => 5}, "junk", nil]})
      assert [%Parcel{weight_g: 5}] = request.parcels
    end
  end

  defp inspect_name(module), do: Atom.to_string(module)

  describe "PickupPoint.manual/1" do
    test "builds a point from the typed code" do
      assert %PickupPoint{
               id: "12",
               number: "12",
               name: "12",
               postcode: nil,
               kind: :other,
               extra: %{"manual" => "true"}
             } = PickupPoint.manual(" 12 ")
    end

    test "does not derive a postcode from the code" do
      for code <- ["36000", "3600", "360000000", "36A00"] do
        assert %PickupPoint{id: ^code, postcode: nil} = PickupPoint.manual(code)
      end
    end

    test "a blank or non-string code has no point" do
      assert PickupPoint.manual("") == nil
      assert PickupPoint.manual("   ") == nil
      assert PickupPoint.manual(nil) == nil
    end

    test "survives a JSON round-trip" do
      point = PickupPoint.manual("36000")

      assert point
             |> PickupPoint.to_map()
             |> Jason.encode!()
             |> Jason.decode!()
             |> PickupPoint.from_map() == point
    end
  end

  describe "Context" do
    test "to_map never exposes credentials, method or opts" do
      context = %Context{
        method: %{uuid: "m-1", name: "Secret method"},
        provider: __MODULE__,
        credentials: %{"api_key" => "SECRET"},
        opts: [req_options: [plug: :x]],
        service: "s"
      }

      map = Context.to_map(context)

      assert map["method_uuid"] == "m-1"
      assert map["provider"] == "Elixir." <> inspect(__MODULE__)
      refute inspect(map) =~ "SECRET"
      refute Map.has_key?(map, "credentials")
      refute Map.has_key?(map, "opts")
    end

    test "inspect hides the credentials" do
      context = %Context{credentials: %{"api_key" => "SECRET"}, service: "s"}

      refute inspect(context) =~ "SECRET"
      assert inspect(context) =~ "service"
    end

    test "from_map resolves registered providers only, by key or module name" do
      assert %Context{provider: Fixed} = Context.from_map(%{"provider" => "fixed"})
      assert %Context{provider: Table} = Context.from_map(%{"provider" => inspect_name(Table)})
      assert %Context{provider: Table} = Context.from_map(%{provider: Table})

      # Loaded modules that are not registered providers stay unresolved.
      assert %Context{provider: nil} = Context.from_map(%{"provider" => inspect_name(Enum)})
      assert %Context{provider: nil} = Context.from_map(%{provider: Enum})
      assert %Context{provider: nil} = Context.from_map(%{provider: nil})
    end

    test "from_map ignores providers that are not loaded" do
      assert %Context{provider: nil} = Context.from_map(%{"provider" => "Elixir.Nope.Nothing"})
      assert %Context{provider: nil} = Context.from_map(%{"provider" => "plain"})
    end
  end

  describe "shipment structs" do
    test "a request without a payer, a known status or a format falls back to the defaults" do
      assert %ShipmentRequest{payer: :shop, parcels: [], cod_amount: nil} =
               ShipmentRequest.from_map(%{"payer" => "carrier", "parcels" => [nil, "x"]})

      assert %TrackingUpdate{status: nil} = TrackingUpdate.from_map(%{"status" => "lost"})
      assert %LabelOptions{format: :a4} = LabelOptions.from_map(%{"format" => "letter"})
    end

    test "the description is cut to 100 characters and blank is nil" do
      assert String.length(ShipmentRequest.description(String.duplicate("x", 150))) == 100
      assert ShipmentRequest.description("   ") == nil
    end

    test "a recipient keeps what it is given, trimmed, and blank values are nil" do
      assert ShipmentRequest.recipient(%{"name" => " Mari ", "email" => "", phone: "5555"}) ==
               %{name: "Mari", company: nil, email: nil, phone: "5555", raw_phone: nil}

      assert ShipmentRequest.recipient(nil) ==
               %{name: nil, company: nil, email: nil, phone: nil, raw_phone: nil}
    end
  end

  describe "ShipmentRequest.e164_phone/2" do
    test "a number without a country code takes the destination country's" do
      assert ShipmentRequest.e164_phone("5555 1234", "EE") == "+37255551234"
      assert ShipmentRequest.e164_phone("(5555) 12-34", "ee") == "+37255551234"
      assert ShipmentRequest.e164_phone("6123 4567", "LV") == "+37161234567"
    end

    test "the national trunk 0 is dropped when the country code is added, except IT, SM and VA" do
      assert ShipmentRequest.e164_phone("067 123 45 67", "UA") == "+380671234567"
      assert ShipmentRequest.e164_phone("040 123 4567", "FI") == "+358401234567"
      assert ShipmentRequest.e164_phone("0151 2345678", "DE") == "+491512345678"
      assert ShipmentRequest.e164_phone("06 1234 5678", "IT") == "+390612345678"
      assert ShipmentRequest.e164_phone("0549 123456", "SM") == "+3780549123456"
      assert ShipmentRequest.e164_phone("06 6988 1234", "VA") == "+390669881234"
    end

    test "each country's own trunk prefix is dropped" do
      # Lithuania: 8 (and 0, the prefix it moves to), 8-digit numbers.
      assert ShipmentRequest.e164_phone("8 612 34567", "LT") == "+37061234567"
      assert ShipmentRequest.e164_phone("0 612 34567", "LT") == "+37061234567"
      assert ShipmentRequest.e164_phone("612 34567", "LT") == "+37061234567"
      # Russia and Kazakhstan: 8, 10-digit numbers; a number that is already
      # ten digits keeps its 8 (St Petersburg is 812).
      assert ShipmentRequest.e164_phone("8 495 123 45 67", "RU") == "+74951234567"
      assert ShipmentRequest.e164_phone("812 123 45 67", "RU") == "+78121234567"
      assert ShipmentRequest.e164_phone("8 701 123 45 67", "KZ") == "+77011234567"
      # Belarus: 8 0, 9-digit numbers.
      assert ShipmentRequest.e164_phone("8 029 123 45 67", "BY") == "+375291234567"
      # Hungary: 06.
      assert ShipmentRequest.e164_phone("06 30 123 4567", "HU") == "+36301234567"
      assert ShipmentRequest.e164_phone("06 1 234 5678", "HU") == "+3612345678"
      # Ukraine: 0, and the old 8 0.
      assert ShipmentRequest.e164_phone("8 067 123 45 67", "UA") == "+380671234567"
      # The US and Canada: 1.
      assert ShipmentRequest.e164_phone("1 212 555 0123", "US") == "+12125550123"
      assert ShipmentRequest.e164_phone("212 555 0123", "US") == "+12125550123"
      # No trunk prefix: Latvia, Poland.
      assert ShipmentRequest.e164_phone("2612 3456", "LV") == "+37126123456"
      assert ShipmentRequest.e164_phone("512 345 678", "PL") == "+48512345678"
    end

    test "a number that fits none of its country's forms is nil, not a guess" do
      assert ShipmentRequest.e164_phone("8 612 345", "LT") == nil
      assert ShipmentRequest.e164_phone("9 495 123 45 67", "RU") == nil
      # A 0 that is not Hungary's 06 trunk: no Hungarian number begins with 0.
      assert ShipmentRequest.e164_phone("030 123 4567", "HU") == nil
      assert ShipmentRequest.e164_phone("0 30 123 4567", "HU") == nil
    end

    test "a 0 typed before a number of a country without a trunk prefix is dropped" do
      # No number there begins with 0, so the 0 is a habit, not a digit.
      assert ShipmentRequest.e164_phone("05123 4567", "EE") == "+37251234567"
      assert ShipmentRequest.e164_phone("0 5123 4567", "EE") == "+37251234567"
      assert ShipmentRequest.e164_phone("02612 3456", "LV") == "+37126123456"
      assert ShipmentRequest.e164_phone("0512 345 678", "PL") == "+48512345678"
      assert ShipmentRequest.e164_phone("0912 345 678", "PT") == "+351912345678"
      # Italy, San Marino and the Vatican keep it: it is part of the number.
      assert ShipmentRequest.e164_phone("06 1234 5678", "IT") == "+390612345678"
    end

    test "an (0) is never dialled from abroad" do
      assert ShipmentRequest.e164_phone("+44 (0)20 7946 0958", nil) == "+442079460958"
      assert ShipmentRequest.e164_phone("(0)151 2345678", "DE") == "+491512345678"
      assert ShipmentRequest.e164_phone("+49 (0) 151 2345678", "EE") == "+491512345678"
    end

    test "an (0) in Italy, San Marino or the Vatican is part of the number" do
      assert ShipmentRequest.e164_phone("+39 (0)6 1234 5678", nil) == "+390612345678"
      assert ShipmentRequest.e164_phone("+378 (0)549 123456", nil) == "+3780549123456"
      assert ShipmentRequest.e164_phone("(0)6 1234 5678", "IT") == "+390612345678"
    end

    test "a number with a country code keeps it" do
      assert ShipmentRequest.e164_phone("+372 5555 1234", "LV") == "+37255551234"
      assert ShipmentRequest.e164_phone("00372 5555 1234", nil) == "+37255551234"
    end

    test "nothing usable is nil" do
      assert ShipmentRequest.e164_phone("5555 1234", nil) == nil
      assert ShipmentRequest.e164_phone("call me", "EE") == nil
      assert ShipmentRequest.e164_phone("+372 12", "EE") == nil
      assert ShipmentRequest.e164_phone("+0 5555 1234 5678 9", "EE") == nil
      assert ShipmentRequest.e164_phone(nil, "EE") == nil
    end
  end
end
