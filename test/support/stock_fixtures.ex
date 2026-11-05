defmodule PhoenixKitEcommerce.StockFixtures do
  @moduledoc """
  Stock tracking in force against the real `phoenix_kit_warehouse`, for tests
  tagged `:warehouse` and `:catalogue`. Every write is a setting or a row inside
  the test's sandbox, so nothing outlives the test.
  """

  @compile {:no_warn_undefined, PhoenixKitWarehouse.StockLedger}

  alias PhoenixKit.Settings
  alias PhoenixKitWarehouse.StockLedger

  @doc "Turns Warehouse and stock tracking on, at a new default location."
  def track_stock! do
    {:ok, _} = Settings.update_boolean_setting_with_module("warehouse_enabled", true, "warehouse")
    location = Ecto.UUID.generate()
    StockLedger.set_default_location_uuid(location)

    {:ok, _} =
      Settings.update_boolean_setting_with_module("shop_stock_tracking_enabled", true, "shop")

    location
  end

  @doc "Sets what is on hand of an item at the default location."
  def put_stock!(item_uuid, quantity) do
    {:ok, row} = StockLedger.upsert_quantity(item_uuid, quantity)
    row
  end

  @doc "What is on hand of an item at the default location."
  def on_hand(item_uuid),
    do: StockLedger.get_quantity(item_uuid, StockLedger.default_location_uuid())
end
