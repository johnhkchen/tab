defmodule Tab.Billing.PaddleTest do
  @moduledoc """
  Paddle's webhook and API (docs/specification.md, "Paddle webhook"), with
  events signed the way Paddle signs them and the API answered by a
  `Req.Test` stub. No network.
  """
  use TabWeb.ConnCase, async: false

  import Tab.AccountsFixtures

  alias Tab.{Accounts, Billing, Repo}
  alias Tab.Accounts.Scope
  alias Tab.Billing.{Account, Paddle}

  @secret "pdl_ntfset_test_secret"

  setup do
    Application.put_env(:tab, :edition, "cloud")
    on_exit(fn -> Application.put_env(:tab, :edition, "self_host") end)
    user = user_fixture()
    :ok = Billing.start(user)
    %{user: user}
  end

  defp sign(body, ts \\ System.system_time(:second), secret \\ @secret) do
    h1 = :crypto.mac(:hmac, :sha256, secret, "#{ts}:#{body}") |> Base.encode16(case: :lower)
    "ts=#{ts};h1=#{h1}"
  end

  defp event(id, type, at, data) do
    %{
      "event_id" => id,
      "event_type" => type,
      "occurred_at" => at,
      "notification_id" => "ntf_" <> id,
      "data" => data
    }
  end

  defp subscription(user_id, status, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "sub_1",
        "status" => status,
        "customer_id" => "ctm_1",
        "custom_data" => %{"user_id" => user_id},
        "items" => [%{"price" => %{"id" => "pri_plus"}}],
        "current_billing_period" => %{
          "starts_at" => "2026-10-16T12:00:00Z",
          "ends_at" => "2027-10-16T12:00:00Z"
        },
        "canceled_at" => nil
      },
      extra
    )
  end

  defp post_event(event, signature \\ nil) do
    body = Jason.encode!(event)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("paddle-signature", signature || sign(body))
    |> post("/paddle/webhook", body)
  end

  test "a signed subscription.created makes the account paid Plus, once", %{user: user} do
    e =
      event(
        "evt_1",
        "subscription.created",
        "2026-10-16T12:00:01.123456Z",
        subscription(user.id, "active")
      )

    assert post_event(e).status == 200
    assert post_event(e).status == 200

    account = Repo.get!(Account, user.id)
    assert account.paid_plan == "plus"
    assert account.paid_until == ~U[2027-10-16 12:00:00Z]
    assert account.paddle_subscription_id == "sub_1"
    assert %{tier: :plus, source: :paid} = Billing.plan(user.id, ~U[2026-11-01 00:00:00Z])
    assert Repo.aggregate("paddle_events", :count) == 1
  end

  test "a bad or stale signature gets 401 and writes nothing", %{user: user} do
    e =
      event(
        "evt_2",
        "subscription.created",
        "2026-10-16T12:00:00Z",
        subscription(user.id, "active")
      )

    body = Jason.encode!(e)

    assert post_event(e, sign(body, System.system_time(:second), "wrong")).status == 401
    assert post_event(e, sign(body, System.system_time(:second) - 3600)).status == 401
    assert post_event(e, "ts=1;h1=").status == 401
    assert Repo.aggregate("paddle_events", :count) == 0
    assert Repo.get!(Account, user.id).paid_plan == nil
  end

  test "several h1 values while a secret rotates: any match counts" do
    body = ~s({"a":1})
    ts = System.system_time(:second)
    good = :crypto.mac(:hmac, :sha256, @secret, "#{ts}:#{body}") |> Base.encode16(case: :lower)
    assert Paddle.verify(body, "ts=#{ts};h1=deadbeef;h1=#{good}", @secret, ts)
    refute Paddle.verify(body, "ts=#{ts};h1=deadbeef", @secret, ts)
  end

  test "a database refusal gets 503 so Paddle retries", %{user: user} do
    e =
      event(
        String.duplicate("x", 150),
        "subscription.created",
        "2026-10-16T12:00:00Z",
        subscription(user.id, "active")
      )

    assert post_event(e).status == 503
  end

  test "an older event after a newer one changes nothing", %{user: user} do
    newer =
      event(
        "evt_new",
        "subscription.updated",
        "2026-10-20T00:00:00Z",
        subscription(user.id, "active", %{
          "current_billing_period" => %{"ends_at" => "2028-01-01T00:00:00Z"}
        })
      )

    older =
      event(
        "evt_old",
        "subscription.updated",
        "2026-10-18T00:00:00Z",
        subscription(user.id, "active")
      )

    assert post_event(newer).status == 200
    assert post_event(older).status == 200
    assert Repo.get!(Account, user.id).paid_until == ~U[2028-01-01 00:00:00Z]
  end

  test "cancelled in the portal: Plus until the period ends; for a refund: at once", %{user: user} do
    post_event(
      event(
        "evt_a",
        "subscription.created",
        "2026-10-16T12:00:00Z",
        subscription(user.id, "active")
      )
    )

    # Cancelling in the portal schedules it; Plus runs to the period's end.
    scheduled =
      subscription(user.id, "active", %{
        "scheduled_change" => %{"action" => "cancel", "effective_at" => "2027-10-16T12:00:00Z"}
      })

    post_event(event("evt_b", "subscription.updated", "2026-11-01T00:00:00Z", scheduled))
    assert Repo.get!(Account, user.id).paid_until == ~U[2027-10-16 12:00:00Z]

    # The operator cancels at once for a refund.
    now =
      subscription(user.id, "canceled", %{
        "current_billing_period" => nil,
        "canceled_at" => "2026-11-02T09:00:00Z"
      })

    post_event(event("evt_c", "subscription.canceled", "2026-11-02T09:00:01Z", now))
    account = Repo.get!(Account, user.id)
    assert account.paid_until == ~U[2026-11-02 09:00:00Z]
    assert %{tier: :plus, source: :trial} = Billing.plan(user.id, ~U[2026-11-03 00:00:00Z])
  end

  test "events for nobody Tab knows are stored, not applied" do
    e =
      event(
        "evt_x",
        "subscription.created",
        "2026-10-16T12:00:00Z",
        subscription(Ecto.UUID.generate(), "active", %{"id" => "sub_other"})
      )

    assert post_event(e).status == 200
    assert Repo.aggregate("paddle_events", :count) == 1
  end

  test "self-host: the webhook isn't there", %{user: user} do
    Application.put_env(:tab, :edition, "self_host")

    e =
      event(
        "evt_s",
        "subscription.created",
        "2026-10-16T12:00:00Z",
        subscription(user.id, "active")
      )

    assert post_event(e).status == 404
  end

  describe "deleting an account with a subscription" do
    setup %{user: user} do
      post_event(
        event(
          "evt_d",
          "subscription.created",
          "2026-10-16T12:00:00Z",
          subscription(user.id, "active")
        )
      )

      :ok
    end

    test "cancels at once and refunds a payment within 30 days", %{user: user} do
      test_pid = self()
      recent = DateTime.utc_now() |> DateTime.add(-3, :day) |> DateTime.to_iso8601()

      Req.Test.stub(Paddle, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:paddle, conn.method, conn.request_path, body})

        case conn.request_path do
          "/transactions" ->
            Req.Test.json(conn, %{"data" => [%{"id" => "txn_1", "billed_at" => recent}]})

          _ ->
            Req.Test.json(conn, %{"data" => %{}})
        end
      end)

      assert {:ok, _} = Accounts.delete_account(Scope.for_user(user))
      assert_received {:paddle, "POST", "/subscriptions/sub_1/cancel", cancel}
      assert Jason.decode!(cancel) == %{"effective_from" => "immediately"}
      assert_received {:paddle, "POST", "/adjustments", refund}

      assert %{"action" => "refund", "transaction_id" => "txn_1", "type" => "full"} =
               Jason.decode!(refund)

      assert Accounts.get_user_by_email(user.email) == nil
    end

    test "no refund past 30 days", %{user: user} do
      test_pid = self()

      Req.Test.stub(Paddle, fn conn ->
        send(test_pid, {:paddle, conn.request_path})

        case conn.request_path do
          "/transactions" ->
            Req.Test.json(conn, %{
              "data" => [%{"id" => "txn_1", "billed_at" => "2026-01-01T00:00:00Z"}]
            })

          _ ->
            Req.Test.json(conn, %{"data" => %{}})
        end
      end)

      assert {:ok, _} = Accounts.delete_account(Scope.for_user(user))
      refute_received {:paddle, "/adjustments"}
    end

    test "if Paddle can't cancel, nothing is deleted", %{user: user} do
      Req.Test.stub(Paddle, &Plug.Conn.send_resp(&1, 500, ""))
      assert {:error, :billing} = Accounts.delete_account(Scope.for_user(user))
      assert Accounts.get_user_by_email(user.email)
    end
  end

  test "the customer portal link" do
    Req.Test.stub(Paddle, fn conn ->
      assert conn.request_path == "/customers/ctm_1/portal-sessions"

      Req.Test.json(conn, %{
        "data" => %{"urls" => %{"general" => %{"overview" => "https://portal.example/x"}}}
      })
    end)

    assert {:ok, "https://portal.example/x"} = Paddle.portal_url("ctm_1")
    assert {:error, :no_customer} = Paddle.portal_url(nil)
  end
end
