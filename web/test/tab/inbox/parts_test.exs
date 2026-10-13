defmodule Tab.Inbox.PartsTest do
  @moduledoc "The pure parts of phase 4: proposal checks, email parsing, webhook signatures, digest dates."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tab.Inbox.{Email, Mail, Proposal, Resend}

  doctest Tab.Inbox.Email
  doctest Tab.Inbox, only: [local_part: 1, search: 3, companies: 1]

  @today ~D[2026-10-13]

  describe "Proposal.validate/2" do
    test "keeps sound fields and blanks the rest" do
      p =
        Proposal.validate(
          %{
            "doc_type" => "utility",
            "merchant" => "  PG&E\n",
            "total_cents" => 8_420,
            "date" => "2026-10-03",
            "due_on" => "not a date",
            "period_start" => "2026-10-01",
            "period_end" => "2026-09-01",
            "account_hint" => "Account 1234-5678-9012",
            "line_items" => []
          },
          @today
        )

      assert p["merchant"] == "PG&E"
      assert p["total_cents"] == 8_420
      assert p["due_on"] == nil
      # Backwards periods go.
      assert {p["period_start"], p["period_end"]} == {nil, nil}
      assert p["account_hint"] == "9012"
    end

    test "amounts must be whole positive cents under a million dollars" do
      for bad <- [0, -1, 100_000_000, 12.5, "12.50", nil] do
        assert Proposal.validate(%{"total_cents" => bad}, @today)["total_cents"] == nil
      end
    end

    test "a carried balance stays out of this period's amount" do
      carried =
        Proposal.validate(
          %{"total_cents" => 31_240, "previous_cents" => 12_390, "past_due" => true},
          @today
        )

      assert {carried["period_cents"], carried["past_due"]} == {18_850, true}

      printed =
        Proposal.validate(
          %{"total_cents" => 31_240, "current_cents" => 18_850, "previous_cents" => 12_390},
          @today
        )

      assert printed["period_cents"] == 18_850

      plain = Proposal.validate(%{"total_cents" => 8_420, "past_due" => "yes"}, @today)
      assert {plain["period_cents"], plain["past_due"]} == {8_420, false}

      # A carried balance bigger than the total (a credit) leaves the total.
      odd = Proposal.validate(%{"total_cents" => 5_000, "previous_cents" => 9_000}, @today)
      assert odd["period_cents"] == 5_000
    end

    test "unknown types become other; junk input is a blank proposal" do
      assert Proposal.validate(%{"doc_type" => "invoice"}, @today)["doc_type"] == "other"
      assert Proposal.validate("nonsense", @today) == Proposal.validate(%{}, @today)
    end

    test "line items stay only when they add up to the total within a dollar" do
      items = [
        %{"description" => "Bananas", "cents" => 200},
        %{"description" => "Wine", "cents" => 2_000}
      ]

      ok =
        Proposal.validate(
          %{"total_cents" => 2_310, "tax_cents" => 110, "line_items" => items},
          @today
        )

      assert length(ok["line_items"]) == 2

      off = Proposal.validate(%{"total_cents" => 9_999, "line_items" => items}, @today)
      assert off["line_items"] == []
    end

    property "whatever comes back, the proposal has only known keys and sane values" do
      check all(
              raw <- map_of(string(:printable, max_length: 12), term(), max_length: 8),
              total <- one_of([integer(), constant(nil)])
            ) do
        p = Proposal.validate(Map.put(raw, "total_cents", total), @today)
        assert Map.keys(p) |> Enum.sort() == Map.keys(Proposal.blank()) |> Enum.sort()

        assert p["total_cents"] == nil or
                 (p["total_cents"] > 0 and p["total_cents"] < 100_000_000)
      end
    end
  end

  describe "Email.parse/1" do
    defp mime(parts, headers \\ "From: PG&E <billing@pge.com>\r\nSubject: Your bill\r\n") do
      body =
        Enum.map_join(parts, "", fn {type, extra, content} ->
          "--XX\r\nContent-Type: #{type}\r\n#{extra}\r\n#{content}\r\n"
        end)

      headers <>
        "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"XX\"\r\n\r\n" <>
        body <> "--XX--\r\n"
    end

    test "picks the PDF over the text" do
      raw =
        mime([
          {"text/plain; charset=utf-8", "", "Your bill is $84.20."},
          {"application/pdf; name=\"bill.pdf\"",
           "Content-Disposition: attachment; filename=\"bill.pdf\"\r\nContent-Transfer-Encoding: base64\r\n",
           Base.encode64("%PDF-1.4 bill")}
        ])

      assert {:ok, email} = Email.parse(raw)
      assert email.from == "PG&E <billing@pge.com>"
      assert email.text == "Your bill is $84.20."
      assert {:pdf, "application/pdf", "bill.pdf", "%PDF-1.4 bill"} = email.part
      assert email.gmail_code == nil
    end

    test "falls back to the HTML body with tags and scripts stripped" do
      raw = mime([{"text/html", "", "<p>Amount due: <b>$84.20</b></p><script>alert(1)</script>"}])
      assert {:ok, %{part: nil, text: text}} = Email.parse(raw)
      assert text =~ "Amount due:"
      assert text =~ "$84.20"
      refute text =~ "alert"
    end

    test "forwarded twice (a landlord's forward, forwarded again), it reads the company's own email" do
      raw =
        "From: Priya <priya@gmail.test>\r\nSubject: Fwd: Fwd: Your bill\r\nContent-Type: text/plain\r\n\r\n" <>
          "---------- Forwarded message ---------\r\nFrom: Landlord <landlord@rentals.test>\r\n" <>
          "Date: Mon, Oct 5, 2026 at 9:00 AM\r\nSubject: Fwd: Your bill\r\n\r\nSee below.\r\n\r\n" <>
          "---------- Forwarded message ---------\r\nFrom: <noreply@sfwater.org>\r\n" <>
          "Date: Thu, Sep 24, 2026 at 7:28 PM\r\nSubject: Your bill\r\n\r\nAmount due $50.00\r\n"

      assert {:ok, e} = Email.parse(raw)

      assert {e.sender, e.original_subject, e.sent_on} ==
               {"noreply@sfwater.org", "Your bill", ~D[2026-09-24]}
    end

    test "spots Gmail's forwarding check and its code" do
      raw =
        mime(
          [{"text/plain", "", "Confirmation code: 123456789"}],
          "From: Gmail Team <forwarding-noreply@google.com>\r\nSubject: (#123456789) Gmail Forwarding Confirmation\r\n"
        )

      assert {:ok, %{gmail_code: "123456789"}} = Email.parse(raw)
    end

    test "something that isn't mail is unreadable, not a crash" do
      result = Email.parse(<<0, 1, 2>>)
      assert result == {:error, :unreadable} or match?({:ok, %{part: nil}}, result)
    end
  end

  describe "Resend.verify/4" do
    @secret "whsec_" <> Base.encode64("a-test-secret-for-webhooks-12345")

    test "accepts its own signature and nothing else" do
      body = ~s({"type":"email.received","data":{"email_id":"e1"}})
      ts = "1760000000"
      sig = Resend.sign(body, "msg_1", ts, @secret)

      headers = %{
        "svix-id" => "msg_1",
        "svix-timestamp" => ts,
        "svix-signature" => "v1,old " <> sig
      }

      assert Resend.verify(body, headers, @secret, 1_760_000_100)
      refute Resend.verify(body <> " ", headers, @secret, 1_760_000_100)
      refute Resend.verify(body, %{headers | "svix-id" => "msg_2"}, @secret, 1_760_000_100)

      refute Resend.verify(
               body,
               headers,
               "whsec_" <> Base.encode64("another-secret"),
               1_760_000_100
             )

      # Five minutes either way, then it's a replay.
      refute Resend.verify(body, headers, @secret, 1_760_000_301)
      refute Resend.verify(body, %{}, @secret)
      refute Resend.verify(body, headers, nil)
    end
  end

  describe "digest dates" do
    test "the next digest day comes after today" do
      assert Mail.next_digest([10, 25], ~D[2026-10-03]) == ~D[2026-10-10]
      assert Mail.next_digest([10, 25], ~D[2026-10-10]) == ~D[2026-10-25]
      assert Mail.next_digest([10, 25], ~D[2026-10-27]) == ~D[2026-11-10]
      assert Mail.next_digest([], ~D[2026-10-27]) == nil
    end

    test "due before the next digest can't wait; later can" do
      days = [10, 25]
      assert Mail.due_soon?(~D[2026-10-08], days, ~D[2026-10-07])
      refute Mail.due_soon?(~D[2026-10-15], days, ~D[2026-10-07])
      refute Mail.due_soon?(~D[2026-10-01], days, ~D[2026-10-07])
      refute Mail.due_soon?(nil, days, ~D[2026-10-07])
    end
  end
end
