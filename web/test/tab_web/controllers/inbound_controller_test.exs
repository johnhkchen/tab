defmodule TabWeb.InboundControllerTest do
  @moduledoc """
  Forwarded mail, end to end (docs/specification.md, "Forwarded email"): a
  signed `email.received` webhook, the fetch from Resend (a `Req.Test` stub),
  matching the address, and what lands. Plus the digest: bills arriving
  between digest days send nothing each, then one email together.
  """
  use TabWeb.ConnCase, async: false
  use Oban.Testing, repo: Tab.Repo

  import Tab.AccountsFixtures
  import Swoosh.TestAssertions

  alias Tab.{Inbox, Repo}
  alias Tab.Inbox.{FetchWorker, Item, Mail, Message, ReadWorker, Resend}

  setup do
    scope = user_scope_fixture()
    {:ok, group} = Tab.Groups.create_group(scope, %{name: "Elm Street"})
    {:ok, address} = Inbox.address(scope, group.id)
    flush_emails()
    %{scope: scope, group: group, to: Inbox.address_text(address)}
  end

  # The fixture's sign-in email isn't what these tests are about.
  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp post_event(conn, body, opts \\ []) do
    secret = Application.get_env(:tab, :resend_webhook_secret)
    ts = Integer.to_string(Keyword.get(opts, :ts, System.system_time(:second)))
    sig = Keyword.get(opts, :sig, Resend.sign(body, "msg_1", ts, secret))

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("svix-id", "msg_1")
    |> put_req_header("svix-timestamp", ts)
    |> put_req_header("svix-signature", sig)
    |> post(~p"/inbound/resend", body)
  end

  defp event(id),
    do:
      ~s({"type":"email.received","created_at":"2026-10-13T08:00:00Z","data":{"email_id":"#{id}"}})

  defp raw(from, subject, text) do
    "From: #{from}\r\nTo: x@bills.test\r\nSubject: #{subject}\r\nContent-Type: text/plain\r\n\r\n#{text}\r\n"
  end

  # Resend's API: the email's JSON, then its raw download.
  defp resend_has(id, to, raw) do
    Req.Test.stub(Resend, fn conn ->
      case conn.request_path do
        "/emails/receiving/" <> ^id ->
          Req.Test.json(conn, %{
            "id" => id,
            "to" => [to],
            "from" => "billing@pge.com",
            "subject" => "Your bill",
            "raw" => %{
              "download_url" => "https://downloads.test/raw/#{id}",
              "expires_at" => "2026-10-14T00:00:00Z"
            }
          })

        "/raw/" <> ^id ->
          Plug.Conn.send_resp(conn, 200, raw)
      end
    end)
  end

  test "a signed event lands once, even sent twice, and is fetched into an item",
       %{conn: conn} = ctx do
    assert post_event(conn, event("e_1")).status == 200
    assert post_event(build_conn(), event("e_1")).status == 200
    assert [%Message{id: id, status: "fetching"}] = Repo.all(Message)
    assert [_] = all_enqueued(worker: FetchWorker)

    resend_has(
      "e_1",
      "PG&E Bills <#{ctx.to}>",
      raw("PG&E <billing@pge.com>", "Your October bill", "Amount due $84.20")
    )

    assert :ok = perform_job(FetchWorker, %{message_id: id})

    assert %Message{status: "stored", user_id: uid} = Repo.get!(Message, id)
    assert uid == ctx.scope.user.id
    assert [%Item{source: "email", status: "reading"} = item] = Repo.all(Item)
    # The address says which group it's for.
    assert item.group_id == ctx.group.id
    assert_enqueued(worker: ReadWorker, args: %{item_id: item.id})

    # The reader gets the text and who sent it.
    Req.Test.stub(Tab.Reader, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["kind"] == "email"
      assert body["text"] =~ "$84.20"

      Req.Test.json(conn, %{"doc_type" => "utility", "merchant" => "PG&E", "total_cents" => 8_420})
    end)

    :ok = perform_job(ReadWorker, %{item_id: item.id, user_id: uid})
    item = Repo.get!(Item, item.id)

    assert {item.status, item.doc_type, item.proposal["sender"]} ==
             {"ready", "utility", "billing@pge.com"}
  end

  test "a bad or stale signature is refused and nothing is written", %{conn: conn} do
    assert post_event(conn, event("e_2"), sig: "v1,bm9wZQ==").status == 401

    assert post_event(build_conn(), event("e_2"), ts: System.system_time(:second) - 3600).status ==
             401

    assert Repo.all(Message) == []
  end

  test "other events are thanked and ignored", %{conn: conn} do
    assert post_event(conn, ~s({"type":"email.sent","data":{"email_id":"e_3"}})).status == 200
    assert Repo.all(Message) == []
  end

  test "with receiving not set up, the endpoint isn't there", %{conn: conn} do
    Application.put_env(:tab, :inbound_domain, nil)
    on_exit(fn -> Application.put_env(:tab, :inbound_domain, "bills.test") end)
    assert post_event(conn, event("e_4")).status == 404
  end

  test "mail to an unknown or retired address writes no item", %{conn: conn} = ctx do
    {:ok, _} = Inbox.new_address(ctx.scope, ctx.group.id)

    for {id, to} <- [{"e_5", "nobody@bills.test"}, {"e_6", ctx.to}, {"e_7", "x@elsewhere.test"}] do
      assert post_event(build_conn(), event(id)).status == 200
      resend_has(id, to, raw("a@b.com", "hi", "hello"))
      %Message{id: mid} = Repo.get_by!(Message, provider_id: id)
      assert :ok = perform_job(FetchWorker, %{message_id: mid})
      assert Repo.get!(Message, mid).status == "unmatched"
    end

    _ = conn
    assert Repo.all(Item) == []
  end

  test "someone who left the group gets nothing from its address", ctx do
    Repo.query!("UPDATE memberships SET left_at = now() WHERE user_id = $1", [
      Ecto.UUID.dump!(ctx.scope.user.id)
    ])

    assert post_event(build_conn(), event("e_10")).status == 200
    resend_has("e_10", ctx.to, raw("a@b.com", "bill", "Amount due $5.00"))
    %Message{id: mid} = Repo.get_by!(Message, provider_id: "e_10")
    :ok = perform_job(FetchWorker, %{message_id: mid})

    assert Repo.get!(Message, mid).status == "unmatched"
    assert Repo.all(Item) == []
  end

  test "Gmail's forwarding check shows its code instead of becoming a bill", ctx do
    assert post_event(build_conn(), event("e_8")).status == 200

    resend_has(
      "e_8",
      ctx.to,
      raw(
        "Gmail Team <forwarding-noreply@google.com>",
        "(#987654321) Gmail Forwarding Confirmation",
        "Confirmation code: 987654321"
      )
    )

    %Message{id: mid} = Repo.get_by!(Message, provider_id: "e_8")
    :ok = perform_job(FetchWorker, %{message_id: mid})

    assert {:ok, [%Message{kind: "gmail_check", detail: "987654321"}]} =
             Inbox.recent_mail(ctx.scope)

    assert Repo.all(Item) == []
  end

  test "a message Resend won't hand over is retried, then given up on", ctx do
    assert post_event(build_conn(), event("e_9")).status == 200
    Req.Test.stub(Resend, &Plug.Conn.send_resp(&1, 500, "oops"))
    %Message{id: mid} = Repo.get_by!(Message, provider_id: "e_9")

    assert {:error, _} = perform_job(FetchWorker, %{message_id: mid}, attempt: 1)
    assert :ok = perform_job(FetchWorker, %{message_id: mid}, attempt: 10)
    assert Repo.get!(Message, mid).status == "failed"
    _ = ctx
  end

  describe "the digest" do
    setup ctx do
      reader = fn due ->
        Req.Test.stub(Tab.Reader, fn conn ->
          Req.Test.json(conn, %{
            "doc_type" => "utility",
            "merchant" => "Water",
            "total_cents" => 3_000,
            "due_on" => due
          })
        end)
      end

      %{reader: reader, scope: ctx.scope}
    end

    defp arrive!(scope, data) do
      {:ok, item} = Inbox.upload(scope, %{content_type: "application/pdf", data: data})
      :ok = perform_job(ReadWorker, %{item_id: item.id, user_id: scope.user.id})
      item
    end

    test "bills read between digest days send nothing each, then one digest", ctx do
      ctx.reader.(nil)
      arrive!(ctx.scope, "%PDF-1.4 one")

      # A different bill (another company), not a second copy of the first.
      Req.Test.stub(Tab.Reader, fn conn ->
        Req.Test.json(conn, %{
          "doc_type" => "utility",
          "merchant" => "Electric",
          "total_cents" => 6_000
        })
      end)

      arrive!(ctx.scope, "%PDF-1.4 two")
      refute_enqueued(worker: Mail)

      day = Mail.next_digest([10, 25], Date.utc_today())
      assert :ok = Mail.enqueue_digests(day)
      assert [job] = all_enqueued(worker: Mail)
      assert :ok = perform_job(Mail, job.args)

      assert_email_sent(fn email ->
        assert email.subject == "2 bills to check on Tab"
        assert email.text_body =~ "Water $30.00"
        assert email.text_body =~ "Electric $60.00"
      end)

      # Not a digest day, or nothing waiting: no digest.
      Repo.delete_all(Oban.Job)
      assert :ok = Mail.enqueue_digests(Date.add(day, 1))
      refute_enqueued(worker: Mail)
    end

    test "a bill due before the next digest gets its own email", ctx do
      # Read on the 7th, due the 8th, next digest the 10th.
      ctx.reader.("2026-10-08")
      item = arrive!(ctx.scope, "%PDF-1.4 due soon")
      {:ok, item} = Inbox.get_item(ctx.scope, item.id)
      Repo.delete_all(Oban.Job)

      assert :ok = Mail.maybe_due_soon(ctx.scope, item, ~D[2026-10-07])
      assert_enqueued(worker: Mail, args: %{kind: "due_soon", item_id: item.id})
      :ok = perform_job(Mail, %{kind: "due_soon", user_id: ctx.scope.user.id, item_id: item.id})
      assert_email_sent(subject: "Water is due Oct 8, 2026")

      Repo.delete_all(Oban.Job)
      # Read on Sep 20: the Sep 25 digest comes first, so it can wait.
      assert :ok = Mail.maybe_due_soon(ctx.scope, item, ~D[2026-09-20])
      refute_enqueued(worker: Mail)
    end

    test "a late bill goes in the digest of whoever usually pays it", ctx do
      {:ok, house} = Tab.Groups.create_group(ctx.scope, %{name: "Elm Street"})
      me = ctx.scope.user.id

      {:ok, t} =
        Tab.Bills.create_template(ctx.scope, house.id, %{
          name: "Water",
          default_payer: me,
          default_split: Tab.Bills.Suggest.equal([{:user, me}])
        })

      day = Mail.next_digest([10, 25], Date.utc_today())

      {:ok, _} =
        Tab.Ledger.create_expense(ctx.scope, house.id, %{
          description: "Water",
          amount_cents: 3_000,
          date: Date.add(day, -45),
          paid_by: me,
          split: t.default_split,
          template_id: t.id
        })

      assert :ok = Mail.enqueue_digests(day)
      assert [job] = all_enqueued(worker: Mail)
      assert :ok = perform_job(Mail, job.args)

      assert_email_sent(fn email ->
        assert email.subject == "A bill hasn't come in"
        assert email.text_body =~ "Water in Elm Street"
      end)

      # Logged on time, there's nothing to say.
      Repo.delete_all(Oban.Job)

      assert :skip =
               Mail.build("digest", ctx.scope, %{"day" => Date.to_iso8601(Date.add(day, -40))})
    end

    test "with no digest days, each bill gets its own email", ctx do
      {:ok, _} = Tab.Accounts.update_digest_days(ctx.scope, [])
      ctx.reader.(nil)
      item = arrive!(ctx.scope, "%PDF-1.4 each")
      assert_enqueued(worker: Mail, args: %{kind: "ready", item_id: item.id})
    end
  end
end
