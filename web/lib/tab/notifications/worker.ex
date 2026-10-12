defmodule Tab.Notifications.Worker do
  @moduledoc "Builds one notification email as its recipient and sends it."
  use Oban.Worker, queue: :mail, max_attempts: 5

  use Phoenix.VerifiedRoutes, endpoint: TabWeb.Endpoint, router: TabWeb.Router

  import Swoosh.Email

  require Logger

  alias Tab.Accounts.{Scope, User}
  alias Tab.{Groups, Ledger, Mailer, Repo}
  alias TabWeb.Format

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event, "recipient_id" => recipient_id} = args}) do
    with %User{} = recipient <- Repo.get(User, recipient_id),
         {:ok, email} <- build(event, Scope.for_user(recipient), args) do
      send_email(email |> to(recipient.email) |> from(Mailer.from()), event)
    else
      # They can't see it (left the group, or it was deleted): nothing to say.
      _ -> :ok
    end
  end

  defp send_email(email, event) do
    if Mailer.log_only?() do
      Logger.info("No mail provider set up, so a #{event} email was skipped.")
      :ok
    else
      with {:ok, _} <- Mailer.deliver(email), do: :ok
    end
  end

  @doc false
  def build("expense_added", scope, args) do
    with {:ok, ctx} <- context(scope, args),
         {:ok, e} <- Ledger.get_expense(scope, args["record_id"]),
         nil <- e.deleted_at,
         share when share != nil <- Enum.find(e.shares, &(&1.user_id == scope.user.id)) do
      {:ok,
       new()
       |> subject(
         "#{ctx.actor} added #{e.description} (#{Format.money(e.amount_cents)}) in #{ctx.group.name}"
       )
       |> text_body("""
       #{ctx.actor} added an expense in #{ctx.group.name}:

         #{e.description}
         #{Format.money(e.amount_cents)}, paid by #{name(ctx, e.paid_by)}
         Your share: #{Format.money(share.amount_cents)}

       See it: #{url(~p"/groups/#{ctx.group}/expenses/#{e}")}

       #{footer()}
       """)}
    else
      _ -> :skip
    end
  end

  def build("expense_changed", scope, args) do
    with {:ok, ctx} <- context(scope, args),
         {:ok, e} <- Ledger.get_expense(scope, args["record_id"]),
         nil <- e.deleted_at,
         share when share != nil <- Enum.find(e.shares, &(&1.user_id == scope.user.id)) do
      {:ok,
       new()
       |> subject("#{ctx.actor} changed #{e.description} in #{ctx.group.name}")
       |> text_body("""
       #{ctx.actor} changed the amount or split of an expense in #{ctx.group.name}:

         #{e.description}
         Now #{Format.money(e.amount_cents)}, paid by #{name(ctx, e.paid_by)}
         Your share now: #{Format.money(share.amount_cents)}

       See what changed: #{url(~p"/groups/#{ctx.group}/expenses/#{e}")}

       #{footer()}
       """)}
    else
      _ -> :skip
    end
  end

  def build("payment_pending", scope, args) do
    with {:ok, ctx} <- context(scope, args),
         {:ok, payments} <- Ledger.pending_for_me(scope, ctx.group.id),
         %{} = p <- Enum.find(payments, &(&1.id == args["record_id"])) do
      from = if p.from_user_id, do: name(ctx, p.from_user_id), else: "Someone outside the group"

      {:ok,
       new()
       |> subject("Did #{from}'s #{Format.money(p.amount_cents)} arrive?")
       |> text_body("""
       #{ctx.actor} recorded a payment to you in #{ctx.group.name}:

         #{from} sent you #{Format.money(p.amount_cents)} by #{TabWeb.LiveHelpers.method_name(p.method)} on #{Date.to_iso8601(p.date)}#{if p.reference, do: " (#{p.reference})"}

       It counts toward your balance once you say it arrived:
       #{url(~p"/groups/#{ctx.group}")}

       #{footer()}
       """)}
    else
      _ -> :skip
    end
  end

  defp context(scope, %{"group_id" => group_id, "actor_id" => actor_id}) do
    with {:ok, group} <- Groups.get_group(scope, group_id),
         {:ok, members} <- Groups.list_members(scope, group_id) do
      names = Map.new(members, &{&1.user_id, &1.profile.display_name})
      {:ok, %{group: group, names: names, actor: Map.get(names, actor_id, "Someone")}}
    end
  end

  defp name(ctx, id), do: Map.get(ctx.names, id, "a former member")

  defp footer, do: "You get these because you're in a group on Tab."
end
