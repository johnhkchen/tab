defmodule Tab.Billing.MailWorker do
  @moduledoc """
  Emails about a person's plan on Hosted Tab: nearing the month's reading
  allowance, and more trial time granted. Says nothing about their ledger.
  """
  use Oban.Worker, queue: :mail, max_attempts: 5

  import Swoosh.Email

  require Logger

  alias Tab.Accounts.User
  alias Tab.{Mailer, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "user_id" => user_id} = args}) do
    case Repo.get(User, user_id) do
      %User{email: email} = user when is_binary(email) ->
        if String.ends_with?(email, "@deleted.invalid") do
          :ok
        else
          email = build(kind, user, args) |> to(email) |> from(Mailer.from())

          if Mailer.log_only?() do
            Logger.info("No mail provider set up, so a #{kind} email was skipped.")
            :ok
          else
            with {:ok, _} <- Mailer.deliver(email), do: :ok
          end
        end

      _ ->
        :ok
    end
  end

  @doc false
  def build("reading_warning", _user, %{"used" => used, "allowance" => allowance} = args) do
    resumes = args["resumes_on"] |> Date.from_iso8601!() |> Calendar.strftime("%B %-d")

    new()
    |> subject("Tab has read #{used} of your #{allowance} bills this month")
    |> text_body("""
    Tab has read #{used} of the #{allowance} bills your plan covers this month.

    Past #{allowance}, new bills wait in Bills to check until #{resumes}, when
    reading starts again. You can still fill them in yourself any time. Tab
    never charges more for reading.

    #{TabWeb.Endpoint.url()}/plans
    """)
  end

  def build("extension_granted", _user, %{"until" => until}) do
    {:ok, until, _} = DateTime.from_iso8601(until)

    new()
    |> subject("Six more months of Tab Plus")
    |> text_body("""
    Thanks for writing back. Your Tab Plus now runs until #{Calendar.strftime(until, "%B %-d, %Y")},
    and Tab keeps reading your bills until then. No card, and it never turns
    into a paid plan by itself.

    #{TabWeb.Endpoint.url()}/plans
    """)
  end
end
