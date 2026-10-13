defmodule Mix.Tasks.Tab.Mail.PullTest do
  @moduledoc """
  The debug mail puller: it lists everything Resend received across pages,
  saves each email once outside the repo, and can hand them to a dev user's
  Bills to check. Resend is a `Req.Test` stub.
  """
  use Tab.DataCase, async: false
  use Oban.Testing, repo: Tab.Repo

  import Tab.AccountsFixtures

  alias Mix.Tasks.Tab.Mail.Pull
  alias Tab.Inbox.{Item, ReadWorker, Resend}

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    dir = Path.join(System.tmp_dir!(), "tab-mail-pull-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    test_pid = self()

    Req.Test.stub(Resend, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/emails/receiving" ->
          send(test_pid, {:listed, conn.query_params})

          case conn.query_params["after"] do
            nil ->
              Req.Test.json(conn, %{
                "object" => "list",
                "has_more" => true,
                "data" => [email("e_2", "2026-10-13 09:15:00.5+00")]
              })

            "e_2" ->
              Req.Test.json(conn, %{
                "object" => "list",
                "has_more" => false,
                "data" => [email("e_1", "2026-10-12T08:01:02Z")]
              })
          end

        "/emails/receiving/" <> id ->
          Req.Test.json(conn, %{
            "id" => id,
            "to" => ["House <house-abcdefghij@bills.test>"],
            "raw" => %{"download_url" => "https://downloads.test/raw/#{id}"}
          })

        "/raw/" <> id ->
          Plug.Conn.send_resp(
            conn,
            200,
            "From: SFPUC <billing@sfwater.example>\r\nSubject: Autopay #{id}\r\n\r\nYour autopay of $42.00 is scheduled.\r\n"
          )
      end
    end)

    %{dir: dir}
  end

  defp email(id, at) do
    %{
      "id" => id,
      "from" => "SFPUC <billing@sfwater.example>",
      "to" => ["House <house-abcdefghij@bills.test>"],
      "subject" => "Autopay #{id}",
      "created_at" => at,
      "attachments" => [
        %{"id" => "a1", "filename" => "notice.pdf", "content_type" => "application/pdf"}
      ]
    }
  end

  test "lists across pages and saves each email once", %{dir: dir} do
    assert {:ok, [%{"id" => "e_2"}, %{"id" => "e_1"}]} = Resend.list_received(limit: 1)
    assert_received {:listed, %{"limit" => "1"}}
    assert_received {:listed, %{"limit" => "1", "after" => "e_2"}}

    assert :ok = Pull.pull(dir: dir, limit: 1)
    files = dir |> File.ls!() |> Enum.sort()

    assert files == [
             "20261012-080102_e_1.eml",
             "20261012-080102_e_1.json",
             "20261013-091500_e_2.eml",
             "20261013-091500_e_2.json"
           ]

    assert File.read!(Path.join(dir, "20261012-080102_e_1.eml")) =~ "autopay of $42.00"
    note = Jason.decode!(File.read!(Path.join(dir, "20261012-080102_e_1.json")))
    assert note["subject"] == "Autopay e_1"

    assert note["attachments"] == [
             %{"filename" => "notice.pdf", "content_type" => "application/pdf"}
           ]

    assert_received {:mix_shell, :info, [line]} when is_binary(line)

    # A second pull saves nothing new.
    flush()
    assert :ok = Pull.pull(dir: dir)
    lines = shell_lines()
    assert Enum.count(lines, &String.ends_with?(&1, "already have")) == 2
  end

  test "won't save inside the repo" do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    inside = Path.join(String.trim(root), "tmp/mail")
    assert {:error, message} = Pull.pull(dir: inside)
    assert message =~ "inside the repo"
    refute File.exists?(inside)
  end

  test "needs the Resend key", %{dir: dir} do
    Application.put_env(:tab, :resend_api_key, nil)
    on_exit(fn -> Application.put_env(:tab, :resend_api_key, "re_test") end)
    assert {:error, message} = Pull.pull(dir: dir)
    assert message =~ "doppler run --project tab --config dev -- mix tab.mail.pull"
  end

  test "--into hands new emails to that person's Bills to check", %{dir: dir} do
    user = user_fixture()
    assert :ok = Pull.pull(dir: dir, into: user.email)

    items = Repo.all(Item)
    assert length(items) == 2
    assert Enum.all?(items, &(&1.user_id == user.id and &1.source == "email"))
    assert length(all_enqueued(worker: ReadWorker)) == 2

    assert {:error, message} = Pull.pull(dir: dir, into: "nobody@example.com")
    assert message =~ "No Tab user"
  end

  test "--route matches each email to its address's person and group", %{dir: dir} do
    user = user_fixture()
    scope = Tab.Accounts.Scope.for_user(user)
    {:ok, group} = Tab.Groups.create_group(scope, %{name: "House"})

    Repo.insert!(%Tab.Inbox.Address{
      user_id: user.id,
      group_id: group.id,
      local_part: "house-abcdefghij"
    })

    assert :ok = Pull.pull(dir: dir, route: true)
    items = Repo.all(Item)
    assert length(items) == 2
    assert Enum.all?(items, &(&1.user_id == user.id and &1.group_id == group.id))

    # Pulling again routes nothing twice.
    File.rm_rf!(dir)
    assert :ok = Pull.pull(dir: dir, route: true)
    assert length(Repo.all(Item)) == 2
  end

  defp flush do
    receive do
      {:mix_shell, _, _} -> flush()
      {:listed, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp shell_lines(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> shell_lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
