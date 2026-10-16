defmodule Tab.OAuth.OAuthDBTest do
  @moduledoc """
  Row-level security for phase 5's tables (docs/specification.md, "Row-level
  security for the new tables"), in raw SQL through `Repo.as_user/2`: the
  owner, someone else, and nobody, for every verb. Plus `via`, which only the
  session sets.
  """
  use Tab.DataCase, async: true

  import Tab.LedgerSQL

  alias Tab.Repo

  setup do
    owner = person()
    other = person()
    group = create_group!(owner)
    join!(other, group, owner)

    client = new_id()

    owner!(
      "INSERT INTO oauth_clients (id, client_id, kind, name, redirect_uris) VALUES ($1, 'https://claude.example/c.json', 'cimd', 'Claude Code', '{http://localhost/cb}')",
      [client]
    )

    %{owner: owner, other: other, group: group, client: client}
  end

  defp refused?({:error, %Postgrex.Error{postgres: %{code: code}}}),
    do: code in [:insufficient_privilege, :check_violation]

  defp refused?(_), do: false

  defp count(uid, table), do: run!(uid, "SELECT count(*) FROM #{table}") |> hd() |> hd()

  defp connection!(uid, client) do
    id = new_id()

    run!(
      uid,
      "INSERT INTO oauth_connections (id, client_id, scopes) VALUES ($1, $2, '{tab:read,tab:write}')",
      [id, client]
    )

    id
  end

  defp nobody(sql, params \\ []) do
    Repo.as_nobody(fn ->
      case Repo.query(sql, params) do
        {:ok, r} -> r
        {:error, e} -> Repo.rollback(e)
      end
    end)
  end

  test "oauth_connections: the owner sees, makes, and revokes theirs; nobody else", ctx do
    id = connection!(ctx.owner, ctx.client)
    [[stamped]] = owner!("SELECT user_id::text FROM oauth_connections WHERE id = $1", [id])
    assert stamped == ctx.owner

    assert count(ctx.owner, "oauth_connections") == 1
    assert count(ctx.other, "oauth_connections") == 0

    # A connection made "for" someone else is stamped as the maker.
    forged = new_id()

    run!(
      ctx.other,
      "INSERT INTO oauth_connections (id, user_id, client_id, scopes) VALUES ($1, $2, $3, '{tab:read}')",
      [forged, ctx.owner, ctx.client]
    )

    [[maker]] = owner!("SELECT user_id::text FROM oauth_connections WHERE id = $1", [forged])
    assert maker == ctx.other

    # Others can't revoke it; the owner can't widen it or un-revoke it.
    {:ok, %{num_rows: 0}} =
      run(ctx.other, "UPDATE oauth_connections SET revoked_at = now() WHERE id = $1", [id])

    assert refused?(
             run(ctx.owner, "UPDATE oauth_connections SET scopes = '{tab:read}' WHERE id = $1", [
               id
             ])
           )

    {:ok, %{num_rows: 1}} =
      run(ctx.owner, "UPDATE oauth_connections SET revoked_at = now() WHERE id = $1", [id])

    assert refused?(
             run(ctx.owner, "UPDATE oauth_connections SET revoked_at = NULL WHERE id = $1", [id])
           )

    assert refused?(run(ctx.owner, "DELETE FROM oauth_connections WHERE id = $1", [id]))
    assert {:ok, %{rows: [[0]]}} = nobody("SELECT count(*) FROM oauth_connections")
  end

  test "oauth_clients: only the names of clients you've connected", ctx do
    assert count(ctx.owner, "oauth_clients") == 0
    connection!(ctx.owner, ctx.client)

    assert run!(ctx.owner, "SELECT name FROM oauth_clients") == [["Claude Code"]]
    assert count(ctx.other, "oauth_clients") == 0
    assert refused?(run(ctx.owner, "SELECT redirect_uris FROM oauth_clients"))

    assert refused?(
             run(
               ctx.owner,
               "INSERT INTO oauth_clients (client_id, kind, name, redirect_uris) VALUES ('x', 'dcr', 'x', '{https://x.example/cb}')"
             )
           )

    assert refused?(run(ctx.owner, "UPDATE oauth_clients SET name = 'Mine'"))
    assert refused?(run(ctx.owner, "DELETE FROM oauth_clients"))
  end

  test "oauth_codes and oauth_tokens: no person can touch them", ctx do
    conn_id = connection!(ctx.owner, ctx.client)
    hash = {:bytes, :crypto.hash(:sha256, "t")}

    owner!(
      "INSERT INTO oauth_tokens (connection_id, kind, token_hash, resource, expires_at) VALUES ($1, 'access', $2, 'https://tab.example/mcp', now() + interval '1 hour')",
      [conn_id, hash]
    )

    for uid <- [ctx.owner, ctx.other], table <- ~w(oauth_codes oauth_tokens) do
      assert refused?(run(uid, "SELECT count(*) FROM #{table}"))
      assert refused?(run(uid, "UPDATE #{table} SET revoked_at = now()" |> fix_column(table)))
      assert refused?(run(uid, "DELETE FROM #{table}"))
    end

    assert refused?(
             run(
               ctx.owner,
               "INSERT INTO oauth_tokens (connection_id, kind, token_hash, resource, expires_at) VALUES ($1, 'access', $2, 'x', now())",
               [conn_id, {:bytes, :crypto.hash(:sha256, "u")}]
             )
           )
  end

  defp fix_column(sql, "oauth_codes"), do: String.replace(sql, "revoked_at", "used_at")
  defp fix_column(sql, _), do: sql

  test "via comes from the session, never the row", ctx do
    split = [{ctx.owner, 500}, {ctx.other, 500}]
    web = expense!(ctx.owner, ctx.group, 1_000, split)

    claude =
      Repo.as_user(
        ctx.owner,
        fn ->
          id = new_id()

          Repo.query!(
            "INSERT INTO expenses (id, group_id, description, amount_cents, date, paid_by, split, via) VALUES ($1, $2, 'x', 100, current_date, $3, '{\"type\":\"equal\",\"entries\":[]}', 'web')",
            [Ecto.UUID.dump!(id), Ecto.UUID.dump!(ctx.group), Ecto.UUID.dump!(ctx.owner)]
          )

          Repo.query!("SELECT set_expense_shares($1, $2)", [
            Ecto.UUID.dump!(id),
            [%{"user_id" => ctx.owner, "amount_cents" => 100}]
          ])

          id
        end,
        via: "claude"
      )
      |> elem(1)

    # A client claiming "claude" from the web gets "web".
    forged = new_id()

    run!(
      ctx.owner,
      "INSERT INTO payments (id, group_id, from_user_id, to_user_id, amount_cents, date, method, via) VALUES ($1, $2, $3, $4, 100, current_date, 'cash', 'claude')",
      [forged, ctx.group, ctx.owner, ctx.other]
    )

    assert owner!("SELECT via FROM expenses WHERE id = $1", [web]) == [["web"]]
    assert owner!("SELECT via FROM expenses WHERE id = $1", [claude]) == [["claude"]]
    assert owner!("SELECT via FROM payments WHERE id = $1", [forged]) == [["web"]]
    assert refused?(run(ctx.owner, "UPDATE expenses SET via = 'claude' WHERE id = $1", [web]))
  end
end
