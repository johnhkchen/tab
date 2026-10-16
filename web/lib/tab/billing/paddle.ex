defmodule Tab.Billing.Paddle do
  @moduledoc """
  Paddle Billing, Tab's merchant of record (docs/specification.md, "Paddle
  webhook"): checking a webhook's signature, applying subscription events to
  `billing_accounts`, and the few API calls Tab makes (the customer portal,
  cancelling and refunding when someone deletes their account).

  Webhooks are signed `Paddle-Signature: ts=<unix>;h1=<hex>`: HMAC-SHA256,
  keyed with the endpoint's secret as-is, over `"<ts>:<raw body>"`. Several
  `h1` values can appear while a secret rotates; any match counts.

  The webhook is the only writer of paid fields. Each event is stored by its
  `event_id` in the same transaction that applies it, so a repeat changes
  nothing, and an event older than the last one applied to a subscription is
  stored but not applied.
  """
  import Ecto.Query

  require Logger

  alias Tab.Billing.Account
  alias Tab.Repo

  @tolerance 300
  @refund_days 30

  ## Webhooks

  @doc "Whether `header` signs `body` with `secret`. `now` is Unix seconds."
  def verify(body, header, secret, now \\ System.system_time(:second))

  def verify(body, header, secret, now)
      when is_binary(body) and is_binary(header) and is_binary(secret) and secret != "" do
    parts =
      header
      |> String.split(";", trim: true)
      |> Enum.map(&String.split(&1, "=", parts: 2))

    ts =
      Enum.find_value(parts, fn
        [k, v] -> k == "ts" && v
        _ -> nil
      end)

    sigs = for [k, v] <- parts, k == "h1", do: String.downcase(v)

    with ts when is_binary(ts) <- ts,
         {ts_int, ""} <- Integer.parse(ts),
         true <- abs(now - ts_int) <= @tolerance do
      expected =
        :crypto.mac(:hmac, :sha256, secret, ts <> ":" <> body) |> Base.encode16(case: :lower)

      Enum.any?(sigs, &Plug.Crypto.secure_compare(&1, expected))
    else
      _ -> false
    end
  end

  def verify(_, _, _, _), do: false

  @doc """
  Stores an event and applies it, in one transaction. `{:ok, :applied |
  :stored | :duplicate}`.
  """
  def handle(%{"event_id" => id, "event_type" => type, "occurred_at" => at} = event)
      when is_binary(id) and is_binary(type) do
    {:ok, occurred_at, _} = DateTime.from_iso8601(at)

    Repo.transact(fn ->
      {n, _} =
        Repo.insert_all(
          "paddle_events",
          [
            %{
              event_id: id,
              event_type: type,
              occurred_at: DateTime.to_naive(occurred_at),
              payload: event
            }
          ],
          on_conflict: :nothing
        )

      result =
        cond do
          n == 0 ->
            :duplicate

          String.starts_with?(type, "subscription.") ->
            apply_subscription(event["data"], occurred_at)

          true ->
            :stored
        end

      if n == 1 do
        from(e in "paddle_events", where: e.event_id == ^id)
        |> Repo.update_all(set: [processed_at: NaiveDateTime.utc_now(:second)])
      end

      {:ok, result}
    end)
  end

  def handle(_), do: {:error, :bad_event}

  defp apply_subscription(%{"id" => sub_id} = sub, occurred_at) do
    case account_for(sub) do
      nil ->
        :stored

      %Account{subscription_event_at: last} = account
      when not is_nil(last) ->
        if DateTime.compare(occurred_at, last) == :gt,
          do: update(account, sub, sub_id, occurred_at),
          else: :stored

      account ->
        update(account, sub, sub_id, occurred_at)
    end
  end

  defp apply_subscription(_, _), do: :stored

  defp update(account, sub, sub_id, occurred_at) do
    plan = plan_for(sub) || account.paid_plan

    account
    |> Ecto.Changeset.change(
      paid_plan: plan,
      paid_until: paid_until(sub, account.paid_until, occurred_at),
      paddle_subscription_id: sub_id,
      paddle_customer_id: sub["customer_id"] || account.paddle_customer_id,
      subscription_status: sub["status"],
      subscription_event_at: usec(occurred_at)
    )
    |> Repo.update!()

    :applied
  end

  # Active, trialing, and past due run to the end of the current period
  # (Paddle retries a failed card meanwhile). Cancelled ends when it was
  # cancelled: at the period's end when someone cancels in the portal, at
  # once when the operator cancels for a refund. Paused ends now.
  defp paid_until(%{"status" => status} = sub, previous, occurred_at) do
    case status do
      s when s in ~w(active trialing past_due) ->
        timestamp(get_in(sub, ["current_billing_period", "ends_at"])) || previous

      "canceled" ->
        timestamp(sub["canceled_at"]) || DateTime.truncate(occurred_at, :second)

      "paused" ->
        DateTime.truncate(occurred_at, :second)

      _ ->
        previous
    end
  end

  # Paddle's times may or may not carry fractions of a second.
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp timestamp(nil), do: nil

  defp timestamp(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  # Checkout puts the person's id in custom_data; later events are matched
  # by subscription id too.
  defp account_for(sub) do
    by_user =
      with %{"user_id" => uid} <- sub["custom_data"] || %{},
           {:ok, uid} <- Ecto.UUID.cast(uid) do
        Repo.get(Account, uid)
      else
        _ -> nil
      end

    by_user || Repo.get_by(Account, paddle_subscription_id: sub["id"])
  end

  defp plan_for(sub) do
    prices = for item <- sub["items"] || [], do: get_in(item, ["price", "id"])
    plus = Application.get_env(:tab, :paddle)[:plus_price_id]
    pro = Application.get_env(:tab, :paddle)[:pro_price_id]

    cond do
      pro && pro in prices -> "pro"
      plus && plus in prices -> "plus"
      true -> nil
    end
  end

  ## The API

  @doc "A link to Paddle's customer portal, where people cancel or change cards."
  def portal_url(customer_id) when is_binary(customer_id) do
    case request(:post, "/customers/#{customer_id}/portal-sessions", %{}) do
      {:ok, %{"data" => %{"urls" => %{"general" => %{"overview" => url}}}}} -> {:ok, url}
      _ -> {:error, :unavailable}
    end
  end

  def portal_url(_), do: {:error, :no_customer}

  @doc """
  Cancels a subscription at once and refunds its latest payment if it was
  within 30 days. For deleting an account.
  """
  def cancel_and_refund(nil), do: :ok

  def cancel_and_refund(sub_id) do
    with {:ok, _} <-
           request(:post, "/subscriptions/#{sub_id}/cancel", %{effective_from: "immediately"}) do
      # A refund that fails is the operator's to finish; the cancel is what
      # matters for deleting the account.
      case refund_recent(sub_id) do
        :ok -> :ok
        error -> Logger.error("Paddle refund for #{sub_id} failed: #{inspect(error)}")
      end

      :ok
    end
  end

  defp refund_recent(sub_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@refund_days, :day)

    with {:ok, %{"data" => txns}} <-
           request(
             :get,
             "/transactions?subscription_id=#{sub_id}&status=completed&order_by=billed_at[DESC]",
             nil
           ),
         %{"id" => txn_id} <-
           Enum.find(txns, fn t ->
             match?({:ok, _, _}, DateTime.from_iso8601(t["billed_at"] || "")) and
               DateTime.compare(elem(DateTime.from_iso8601(t["billed_at"]), 1), cutoff) == :gt
           end) do
      case request(:post, "/adjustments", %{
             action: "refund",
             transaction_id: txn_id,
             type: "full",
             reason: "Account deleted within 30 days of payment"
           }) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      # Nothing paid in the last 30 days: nothing to refund.
      nil -> :ok
      error -> error
    end
  end

  defp request(method, path, body) do
    config = Application.get_env(:tab, :paddle, [])

    base =
      if config[:env] == "production",
        do: "https://api.paddle.com",
        else: "https://sandbox-api.paddle.com"

    options =
      Keyword.merge(
        [
          method: method,
          url: base <> path,
          auth: {:bearer, config[:api_key] || ""},
          retry: false,
          receive_timeout: 15_000
        ] ++ if(body, do: [json: body], else: []),
        Application.get_env(:tab, :paddle_req, [])
      )

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:paddle, status}}
      {:error, _} -> {:error, :unreachable}
    end
  end
end
