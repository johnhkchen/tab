defmodule Tab.Billing do
  @moduledoc """
  Plans on Hosted Tab (docs/specification.md, "Phase 6"). Everything here is
  dark unless `TAB_EDITION=cloud`; on self-host, `plan/1` says `:self_host`
  and reading works as in phase 4.

  A plan is worked out from dates, never stored: paid Plus while `paid_until`
  is ahead, else trial Plus while `trial_until` is, else Hosted free. Paid
  fields change only through the Paddle webhook (`Tab.Billing.Paddle`), and
  trial dates only here, at sign-up and when the operator grants more time.

  Like `Tab.OAuth`, this module works on its own tables as the connection
  owner: the person isn't always the one acting (a webhook, the operator).
  It reads no ledger data, ever.
  """
  import Ecto.Query

  alias Tab.Accounts.{Scope, User}
  alias Tab.Billing.{Account, ExtensionRequest, MailWorker, Read}
  alias Tab.Repo

  @trial_months 3
  @extension_months 6
  @allowances %{paid_plus: 100, paid_pro: 300, trial: 20}

  @questions [
    "What do you use Tab for?",
    "Would you write a few words we can quote? (Honest is fine, and you can say no.)"
  ]

  @doc "Whether this server is Hosted Tab (`TAB_EDITION=cloud`)."
  def cloud?, do: Application.get_env(:tab, :edition) == "cloud"

  ## Sign-up

  @doc """
  Whether today's new accounts have reached `TAB_SIGNUPS_PER_DAY`. Counts
  accounts that confirmed today, so addresses nobody confirms don't use up
  the day.
  """
  def signups_full?(now \\ now()) do
    cloud?() and
      Repo.aggregate(
        from(a in Account, where: a.inserted_at >= ^start_of_day(now)),
        :count
      ) >= Application.get_env(:tab, :signups_per_day, 50)
  end

  @doc """
  Called when someone confirms their address: makes their billing account,
  with 3 months of trial Plus the first time an address is ever seen.
  """
  def start(%User{} = user, now \\ now()) do
    if cloud?() and is_nil(Repo.get(Account, user.id)) do
      hash = :crypto.hash(:sha256, String.downcase(user.email))

      {first?, _} =
        Repo.insert_all("trial_emails", [%{email_hash: hash}], on_conflict: :nothing)
        |> then(fn {n, rows} -> {n == 1, rows} end)

      Repo.insert!(
        %Account{
          user_id: user.id,
          trial_until: if(first?, do: add_months(now, @trial_months))
        },
        on_conflict: :nothing,
        conflict_target: :user_id
      )
    end

    :ok
  end

  ## The plan

  @doc """
  The person's plan right now:

    * `%{tier: :self_host}` on self-host,
    * `%{tier: :plus | :pro, source: :paid | :trial, until: datetime}`,
    * `%{tier: :free, trial_ended: datetime | nil}`.
  """
  def plan(user_id, now \\ now()) do
    if cloud?(), do: plan_of(Repo.get(Account, user_id), now), else: %{tier: :self_host}
  end

  @doc false
  def plan_of(account, now) do
    cond do
      is_nil(account) ->
        %{tier: :free, trial_ended: nil}

      account.paid_plan && after?(account.paid_until, now) ->
        %{
          tier: String.to_existing_atom(account.paid_plan),
          source: :paid,
          until: account.paid_until
        }

      after?(account.trial_until, now) ->
        %{tier: :plus, source: :trial, until: account.trial_until}

      true ->
        %{tier: :free, trial_ended: account.trial_until}
    end
  end

  @doc "Documents a month the plan reads; `:unlimited` on self-host."
  def allowance(%{tier: :self_host}), do: :unlimited
  def allowance(%{tier: :plus, source: :paid}), do: @allowances.paid_plus
  def allowance(%{tier: :pro, source: :paid}), do: @allowances.paid_pro
  def allowance(%{source: :trial}), do: @allowances.trial
  def allowance(%{tier: :free}), do: 0

  ## Reading

  @doc "Documents read for the person this calendar month (UTC)."
  def reads_this_month(user_id, now \\ now()) do
    Repo.aggregate(
      from(r in Read, where: r.user_id == ^user_id and r.read_on >= ^month_start(now)),
      :count
    )
  end

  @doc """
  Whether Tab may read one more document for the person:
  `{:ok, paid?}`, `{:error, :no_plan}` on Hosted free, or
  `{:error, {:limit, resumes_on}}` when the month's allowance is used.
  """
  def may_read(user_id, now \\ now()) do
    plan = plan(user_id, now)

    case allowance(plan) do
      :unlimited ->
        {:ok, true}

      0 ->
        {:error, :no_plan}

      n ->
        if reads_this_month(user_id, now) < n,
          do: {:ok, plan[:source] == :paid},
          else: {:error, {:limit, next_month(now)}}
    end
  end

  @doc """
  Counts a document the reader looked at (Hosted Tab only), and emails the
  person once a month when they pass 80% of their allowance.
  """
  def record_read(user_id, document_id, paid?, now \\ now()) do
    if cloud?() do
      Repo.insert!(%Read{
        user_id: user_id,
        document_id: document_id,
        paid: paid?,
        read_on: DateTime.to_date(now),
        inserted_at: now
      })

      maybe_warn(user_id, now)
    end

    :ok
  end

  defp maybe_warn(user_id, now) do
    plan = plan(user_id, now)
    allowance = allowance(plan)
    used = reads_this_month(user_id, now)
    month = month_start(now)

    if is_integer(allowance) and allowance > 0 and used * 5 >= allowance * 4 do
      {count, _} =
        from(a in Account,
          where: a.user_id == ^user_id and (is_nil(a.warned_month) or a.warned_month != ^month)
        )
        |> Repo.update_all(set: [warned_month: month])

      if count == 1 do
        Oban.insert!(
          MailWorker.new(%{
            kind: "reading_warning",
            user_id: user_id,
            used: used,
            allowance: allowance,
            resumes_on: Date.to_iso8601(next_month(now))
          })
        )
      end
    end

    :ok
  end

  @doc "Oban priority for reading: paid and self-host first, trial after."
  def read_priority(user_id) do
    case plan(user_id) do
      %{source: :trial} -> 3
      _ -> 0
    end
  end

  ## Asking for more

  @doc """
  The question to ask if the person may ask for more time now, else nil:
  from two weeks before a trial ends, or any time after one ended, with no
  request already waiting and no paid plan.
  """
  def extension_question(%Scope{user: user}, now \\ now()) do
    plan = plan(user.id, now)

    eligible =
      case plan do
        %{source: :trial, until: until} -> DateTime.diff(until, now, :day) <= 14
        %{tier: :free, trial_ended: %DateTime{}} -> true
        _ -> false
      end

    waiting? =
      Repo.exists?(
        from(r in ExtensionRequest, where: r.user_id == ^user.id and r.status == "waiting")
      )

    if eligible and not waiting? do
      asked = Repo.aggregate(from(r in ExtensionRequest, where: r.user_id == ^user.id), :count)
      if asked == 0, do: hd(@questions), else: List.last(@questions)
    end
  end

  @doc "Whether the person has a request waiting for the operator."
  def request_waiting?(%Scope{user: user}) do
    Repo.exists?(
      from(r in ExtensionRequest, where: r.user_id == ^user.id and r.status == "waiting")
    )
  end

  @doc "Asks for 6 more months, as the person (row-level security applies)."
  def request_extension(%Scope{} = scope, attrs) do
    case extension_question(scope) do
      nil ->
        {:error, :not_now}

      question ->
        changeset =
          ExtensionRequest.changeset(
            %ExtensionRequest{id: Ecto.UUID.generate(), question: question},
            attrs
          )

        Tab.DBError.as_user(scope, fn -> Repo.insert(changeset) end)
    end
  end

  ## The operator (`/admin`)

  @doc "Whether this person may open `/admin` (`TAB_ADMIN_EMAILS`)."
  def admin?(%Scope{user: %User{email: email}}) do
    cloud?() and String.downcase(email) in Application.get_env(:tab, :admin_emails, [])
  end

  def admin?(_), do: false

  @doc "Requests waiting, oldest first, with each person's email."
  def waiting_requests do
    Repo.all(
      from r in ExtensionRequest,
        join: u in User,
        on: u.id == r.user_id,
        where: r.status == "waiting",
        order_by: r.inserted_at,
        select: %{request: r, email: u.email}
    )
  end

  @doc "Grants a waiting request: 6 more months of trial Plus, and an email."
  def grant(request_id, now \\ now()), do: decide(request_id, "granted", now)

  @doc "Declines a waiting request. No email."
  def decline(request_id, now \\ now()), do: decide(request_id, "declined", now)

  defp decide(request_id, status, now) do
    Repo.transact(fn ->
      with %ExtensionRequest{status: "waiting"} = r <- Repo.get(ExtensionRequest, request_id),
           {1, _} <-
             from(x in ExtensionRequest, where: x.id == ^r.id and x.status == "waiting")
             |> Repo.update_all(set: [status: status, decided_at: now, updated_at: now]) do
        if status == "granted" do
          account = Repo.get(Account, r.user_id) || Repo.insert!(%Account{user_id: r.user_id})
          from_date = if after?(account.trial_until, now), do: account.trial_until, else: now
          until = add_months(from_date, @extension_months)

          from(a in Account, where: a.user_id == ^r.user_id)
          |> Repo.update_all(set: [trial_until: until, updated_at: now])

          Oban.insert!(
            MailWorker.new(%{
              kind: "extension_granted",
              user_id: r.user_id,
              until: DateTime.to_iso8601(until)
            })
          )
        end

        {:ok, status}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc "The numbers on `/admin`. Counts only; no ledger data."
  def stats(now \\ now()) do
    accounts = Repo.all(Account)
    plans = Enum.map(accounts, &plan_of(&1, now))
    month = month_start(now)
    read = Repo.aggregate(from(r in Read, where: r.read_on >= ^month), :count)

    mail_today =
      Repo.aggregate(
        from(m in "inbound_messages",
          where: m.received_at >= ^DateTime.to_naive(start_of_day(now))
        ),
        :count
      )

    %{
      accounts: length(accounts),
      trials: Enum.count(plans, &(&1[:source] == :trial)),
      paid_plus: Enum.count(plans, &(&1[:source] == :paid and &1.tier == :plus)),
      paid_pro: Enum.count(plans, &(&1[:source] == :paid and &1.tier == :pro)),
      free: Enum.count(plans, &(&1.tier == :free)),
      reads_this_month: read,
      # About $0.002 a document, measured on real bills in phase 4.
      read_cost_estimate_cents: div(read * 2 + 9, 10),
      mail_today: mail_today
    }
  end

  ## Dates

  defp now, do: DateTime.utc_now(:second)
  defp after?(nil, _), do: false
  defp after?(dt, now), do: DateTime.compare(dt, now) == :gt

  defp start_of_day(now), do: DateTime.new!(DateTime.to_date(now), ~T[00:00:00])
  defp month_start(now), do: now |> DateTime.to_date() |> Date.beginning_of_month()
  defp next_month(now), do: now |> month_start() |> Date.shift(month: 1)

  defp add_months(%DateTime{} = dt, n), do: DateTime.shift(dt, month: n)
end
