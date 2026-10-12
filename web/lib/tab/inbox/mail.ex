defmodule Tab.Inbox.Mail do
  @moduledoc """
  Email about the inbox (docs/specification.md, "The digest"): one digest on
  each of a person's digest days, and a note right away for a bill due before
  the next one. With no digest days set, each bill gets its own note.

  Like `Tab.Notifications`, each email is a job built as its recipient.
  """
  use Oban.Worker,
    queue: :mail,
    max_attempts: 5,
    unique: [keys: [:kind, :user_id, :day, :item_id], period: :infinity]

  use Phoenix.VerifiedRoutes, endpoint: TabWeb.Endpoint, router: TabWeb.Router

  import Swoosh.Email, except: [new: 1]

  require Logger

  alias Tab.Accounts.{Scope, User}
  alias Tab.{Accounts, Inbox, Mailer, Repo}
  alias Tab.Inbox.Item
  alias TabWeb.Format

  @doc "The first digest day after `today`, or nil with none set."
  def next_digest([], _today), do: nil

  def next_digest(days, today) do
    Stream.iterate(Date.add(today, 1), &Date.add(&1, 1))
    |> Enum.find(&(&1.day in days))
  end

  @doc "Whether an item due on `due_on` can't wait for the next digest."
  def due_soon?(nil, _days, _today), do: false

  def due_soon?(due_on, days, today) do
    case next_digest(days, today) do
      nil -> false
      next -> Date.compare(due_on, today) != :lt and Date.compare(due_on, next) == :lt
    end
  end

  @doc "Queues a note about a just-read item if it can't wait for the digest."
  def maybe_due_soon(%Scope{user: user} = scope, %Item{} = item, today \\ Date.utc_today()) do
    days = Accounts.get_profile(scope).digest_days

    cond do
      days == [] -> enqueue("ready", user.id, item.id)
      due_soon?(item.due_on, days, today) -> enqueue("due_soon", user.id, item.id)
      true -> :ok
    end
  end

  @doc "Queues today's digest for everyone who has one due."
  def enqueue_digests(today \\ Date.utc_today()) do
    for user_id <- Inbox.Receiving.digest_recipients(today) do
      {:ok, _} =
        Oban.insert(new(%{kind: "digest", user_id: user_id, day: Date.to_iso8601(today)}))
    end

    :ok
  end

  defp enqueue(kind, user_id, item_id) do
    {:ok, _} = Oban.insert(new(%{kind: kind, user_id: user_id, item_id: item_id}))
    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "user_id" => user_id} = args}) do
    with %User{} = user <- Repo.get(User, user_id),
         {:ok, email} <- build(kind, Scope.for_user(user), args) do
      if Mailer.log_only?() do
        Logger.info("No mail provider set up, so a #{kind} email was skipped.")
        :ok
      else
        with {:ok, _} <- Mailer.deliver(email |> to(user.email) |> from(Mailer.from())), do: :ok
      end
    else
      _ -> :ok
    end
  end

  @doc false
  def build("digest", scope, _args) do
    case ready(scope) do
      [] ->
        :skip

      items ->
        {:ok,
         new()
         |> subject(count(items) <> " to check on Tab")
         |> text_body("""
         These came in since you last looked. Check each one and save it, or drop it:

         #{Enum.map_join(items, "\n", &line/1)}

         #{url(~p"/inbox")}

         #{footer()}
         """)}
    end
  end

  def build(kind, scope, %{"item_id" => id}) when kind in ~w(due_soon ready) do
    with {:ok, %Item{status: status} = item} when status in ~w(ready unreadable) <-
           Inbox.get_item(scope, id) do
      {:ok,
       new()
       |> subject(
         if kind == "due_soon",
           do: "#{what(item)} is due #{TabWeb.LiveHelpers.format_date(item.due_on)}",
           else: "#{what(item)} is ready to check"
       )
       |> text_body("""
       #{line(item)}

       Check it and save it: #{url(~p"/inbox/#{item}")}

       #{footer()}
       """)}
    else
      _ -> :skip
    end
  end

  defp ready(scope) do
    {:ok, items} = Inbox.list_items(scope)
    Enum.filter(items, &(&1.status in ~w(ready unreadable)))
  end

  defp count([_]), do: "1 bill"
  defp count(items), do: "#{length(items)} bills"

  defp what(%Item{proposal: p}), do: p["merchant"] || "A bill"

  defp line(%Item{proposal: p} = item) do
    amount = if p["total_cents"], do: " #{Format.money(p["total_cents"])}", else: ""
    due = if item.due_on, do: ", due #{TabWeb.LiveHelpers.format_date(item.due_on)}", else: ""
    "  #{what(item)}#{amount}#{due}"
  end

  defp footer,
    do: "You get these because you send bills to Tab. Pick which days on your You page."
end
