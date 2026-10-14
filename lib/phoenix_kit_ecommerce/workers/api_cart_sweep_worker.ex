defmodule PhoenixKitEcommerce.Workers.ApiCartSweepWorker do
  @moduledoc """
  Hourly sweep of the carts the public cart API created: `active`
  carts whose `session_id` starts with `api:` and that have not been touched
  for `api_cart_idle_days` become `abandoned`.

  Only `api:` carts: a cart a buyer claimed has the buyer's session id (or is
  `merged`), guest and user carts never start with `api:` (the storefront's
  ids are base64url without a colon). A cart with a live checkout link (an
  unused, unsuperseded, unexpired claim) is left alone until the link dies, so
  the buyer who opens it does not find the cart abandoned. General cart expiry
  stays as it is. A link issued in the same instant as a sweep can still find
  its cart abandoned (the sweep decides on the claims it saw); the buyer who
  opens it is answered with the friendly "used or expired" page.
  Does nothing while the shop module is disabled.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitEcommerce.API.CartSettings
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim

  @impl Oban.Worker
  def perform(_job) do
    if PhoenixKitEcommerce.enabled?() do
      {:ok, count} = sweep()
      if count > 0, do: Logger.info("[Shop] abandoned #{count} idle assistant carts")
    end

    :ok
  end

  @doc """
  Abandons the idle `api:` carts and stamps `updated_at` with `now`, so the 30
  days before `ApiCartPruneWorker` deletes it count from here.
  """
  @spec sweep(DateTime.t()) :: {:ok, non_neg_integer()}
  def sweep(now \\ UtilsDate.utc_now()) do
    threshold = DateTime.add(now, -CartSettings.idle_days() * 86_400, :second)

    {count, _} =
      from(c in Cart,
        as: :cart,
        where: c.status == "active",
        where: like(c.session_id, "api:%"),
        where: c.updated_at < ^threshold,
        where:
          not exists(
            from(k in CartClaim,
              where:
                k.cart_uuid == parent_as(:cart).uuid and is_nil(k.used_at) and
                  is_nil(k.superseded_at) and k.expires_at > ^now
            )
          )
      )
      |> RepoHelper.repo().update_all(set: [status: "abandoned", updated_at: now])

    {:ok, count}
  end
end
