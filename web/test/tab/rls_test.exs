defmodule Tab.RlsTest do
  # Proves the RLS plumbing in priv/repo/migrations/*_rls_foundation.exs works
  # before any real table depends on it.
  # Not async: tests create tables with fixed names inside their sandbox transaction.
  use Tab.DataCase, async: false

  alias Tab.Repo

  @alice "00000000-0000-4000-8000-00000000000a"
  @bob "00000000-0000-4000-8000-00000000000b"

  test "tab_user can't log in, isn't a superuser, and can't bypass RLS" do
    %{rows: [[login, super, bypass]]} =
      Repo.query!(
        "SELECT rolcanlogin, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = 'tab_user'"
      )

    assert {login, super, bypass} == {false, false, false}
  end

  test "tab_user has no DELETE by default (no hard deletes)" do
    Repo.query!("CREATE TABLE delete_probe (id int)")

    %{rows: [[can_delete]]} =
      Repo.query!("SELECT has_table_privilege('tab_user', 'delete_probe', 'DELETE')")

    refute can_delete
  end

  test "auth.uid() is the person the transaction acts for, and NULL otherwise" do
    assert %{rows: [[nil]]} = Repo.query!("SELECT auth.uid()")

    {:ok, uid} = Repo.as_user(@alice, fn -> Repo.query!("SELECT auth.uid()::text").rows end)
    assert uid == [[@alice]]

    assert %{rows: [[nil]]} = Repo.query!("SELECT auth.uid()")
  end

  describe "a table with an owner-only policy" do
    setup do
      Repo.query!("CREATE TABLE notes (owner uuid NOT NULL, body text NOT NULL)")
      Repo.query!("ALTER TABLE notes ENABLE ROW LEVEL SECURITY")
      Repo.query!("CREATE POLICY notes_select ON notes FOR SELECT USING (owner = auth.uid())")

      Repo.query!(
        "CREATE POLICY notes_insert ON notes FOR INSERT WITH CHECK (owner = auth.uid())"
      )

      Repo.query!("GRANT SELECT, INSERT ON notes TO tab_user")

      Repo.query!("INSERT INTO notes VALUES ($1, 'alice''s'), ($2, 'bob''s')", [
        Ecto.UUID.dump!(@alice),
        Ecto.UUID.dump!(@bob)
      ])

      :ok
    end

    test "each person reads only their own rows" do
      assert {:ok, [["alice's"]]} = Repo.as_user(@alice, fn -> bodies() end)
      assert {:ok, [["bob's"]]} = Repo.as_user(@bob, fn -> bodies() end)
    end

    test "a person can't write a row as someone else" do
      assert_raise Postgrex.Error, ~r/row-level security/, fn ->
        Repo.as_user(@alice, fn ->
          Repo.query!("INSERT INTO notes VALUES ($1, 'forged')", [Ecto.UUID.dump!(@bob)])
        end)
      end
    end

    test "a person can't delete, even their own rows" do
      assert_raise Postgrex.Error, ~r/permission denied/, fn ->
        Repo.as_user(@alice, fn -> Repo.query!("DELETE FROM notes") end)
      end
    end

    defp bodies, do: Repo.query!("SELECT body FROM notes ORDER BY body").rows
  end
end
