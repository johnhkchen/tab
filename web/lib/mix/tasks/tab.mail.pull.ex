defmodule Mix.Tasks.Tab.Mail.Pull do
  @shortdoc "Saves mail Resend received to a folder outside the repo (development only)"

  @moduledoc """
  Pulls every email Resend has received and saves each one once, as a raw
  `.eml` file and a `.json` note of who sent it, to whom, the subject, and its
  attachments. For looking at real bill emails while working out how Tab
  should handle them. Works without a public webhook.

      doppler run --project tab --config dev -- mix tab.mail.pull
      doppler run --project tab --config dev -- mix tab.mail.pull --into priya@example.com

  Options:

    * `--dir DIR`: where to save (default `~/tab-mail-debug`). It must be
      outside the repo: these emails hold personal bill details.
    * `--into EMAIL`: also hand each new email to Tab as that person, so it
      shows up in their Bills to check and gets read.
    * `--route`: also route each new email the way production does, by the
      forwarding address it was sent to (person and group).
    * `--limit N`: how many to ask Resend for per page (1 to 100).

  Never runs in production.
  """
  use Mix.Task

  alias Tab.Accounts
  alias Tab.Inbox
  alias Tab.Inbox.Resend

  @switches [dir: :string, into: :string, route: :boolean, limit: :integer]

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod, do: Mix.raise("mix tab.mail.pull is for development only.")
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    case pull(opts) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc false
  # Does the work; returns `:ok` or `{:error, message}`. Split out for tests.
  def pull(opts) do
    dir = Path.expand(opts[:dir] || "~/tab-mail-debug")

    with :ok <- outside_repo(dir),
         :ok <- have_key(),
         {:ok, scope} <- scope(opts[:into]),
         {:ok, emails} <- list(opts) do
      File.mkdir_p!(dir)
      mode = if opts[:route], do: :route, else: scope
      Enum.each(emails, &save(&1, dir, mode))
      Mix.shell().info("#{length(emails)} emails at Resend; saved in #{dir}")
      :ok
    end
  end

  defp outside_repo(dir) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} ->
        root = String.trim(root)

        if dir == root or String.starts_with?(dir <> "/", root <> "/"),
          do:
            {:error,
             "#{dir} is inside the repo; these emails hold personal details. Pick a folder outside it."},
          else: :ok

      _ ->
        :ok
    end
  end

  defp have_key do
    if Application.get_env(:tab, :resend_api_key) in [nil, ""],
      do:
        {:error,
         "RESEND_API_KEY isn't set. Run: doppler run --project tab --config dev -- mix tab.mail.pull"},
      else: :ok
  end

  defp scope(nil), do: {:ok, nil}

  defp scope(email) do
    case Accounts.get_user_by_email(email) do
      nil -> {:error, "No Tab user with the email #{email}."}
      user -> {:ok, Accounts.Scope.for_user(user)}
    end
  end

  defp list(opts) do
    case Resend.list_received(limit: opts[:limit] || 100) do
      {:ok, emails} -> {:ok, emails}
      {:error, reason} -> {:error, "Resend didn't list the emails: #{inspect(reason)}"}
    end
  end

  defp save(%{"id" => id} = email, dir, scope) do
    base = Path.join(dir, "#{stamp(email["created_at"])}_#{safe(id)}")
    line = "#{email["created_at"]}  #{email["from"]}  #{email["subject"]}"

    if File.exists?(base <> ".eml") do
      Mix.shell().info("#{line}  already have")
    else
      case Resend.fetch(id, Inbox.max_bytes(:pdf)) do
        {:ok, %{raw: raw} = mail} ->
          File.write!(base <> ".json", Jason.encode!(note(email), pretty: true))
          File.write!(base <> ".eml", raw)
          Mix.shell().info("#{line}  saved#{hand_over(scope, id, mail)}")

        {:error, reason} ->
          Mix.shell().error("#{line}  couldn't fetch: #{inspect(reason)}")
      end
    end
  end

  defp note(email) do
    %{
      id: email["id"],
      from: email["from"],
      to: email["to"],
      subject: email["subject"],
      created_at: email["created_at"],
      attachments:
        for(
          a <- email["attachments"] || [],
          do: %{filename: a["filename"], content_type: a["content_type"]}
        )
    }
  end

  defp hand_over(nil, _id, _mail), do: ""

  defp hand_over(:route, id, mail) do
    case Tab.Inbox.Receiving.route(id, mail) do
      %{status: "stored", kind: "gmail_check"} -> ", Gmail's forwarding code"
      %{status: "stored"} -> ", routed to its address's Bills to check"
      %{status: status} -> ", #{status}"
    end
  end

  defp hand_over(scope, _id, %{raw: raw}) do
    doc = %{
      kind: "email",
      content_type: "message/rfc822",
      filename: nil,
      data: raw,
      source: "email"
    }

    case Inbox.add(scope, doc) do
      {:ok, _} -> ", added to Bills to check"
      {:error, :duplicate} -> ", already in Bills to check"
      {:error, reason} -> ", not added (#{inspect(reason)})"
    end
  end

  # "2026-10-13 08:01:02.123+00" or ISO 8601 -> "20261013-080102".
  defp stamp(created_at) when is_binary(created_at) do
    case Regex.run(~r/(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/, created_at) do
      [_, y, m, d, h, mi, s] -> "#{y}#{m}#{d}-#{h}#{mi}#{s}"
      _ -> "undated"
    end
  end

  defp stamp(_), do: "undated"

  defp safe(id), do: String.replace(id, ~r/[^A-Za-z0-9_-]/, "_")
end
