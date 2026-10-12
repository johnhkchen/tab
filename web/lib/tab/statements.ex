defmodule Tab.Statements do
  @moduledoc """
  Statement links (docs/specification.md, "Statement links"): one person's
  month in a group, readable without signing in, for 30 days or until someone
  revokes it.

  Making and revoking links runs as the signed-in member. Reading one runs as
  nobody (`Tab.Repo.as_nobody/1`) through `read_statement`, which checks the
  token and decides on its own what to show.
  """
  import Ecto.Query
  import Tab.DBError, only: [as_user: 2]
  import Tab.Groups, only: [now: 0, set: 3, touched: 1]

  alias Tab.Accounts.Scope
  alias Tab.Repo
  alias Tab.Statements.Link

  @doc """
  Makes a link for `party` (`{:user, id}` or `{:counterparty, id}`) covering the
  month that `day` falls in. Returns `{:ok, token, link}`; the token appears
  only here, so put it in the URL now.
  """
  def create_link(%Scope{} = scope, group_id, party, day \\ Date.utc_today()) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    start = Date.beginning_of_month(day)

    {user_id, counterparty_id} =
      case party do
        {:user, id} -> {id, nil}
        {:counterparty, id} -> {nil, id}
      end

    link = %Link{
      group_id: group_id,
      token_hash: :crypto.hash(:sha256, token),
      user_id: user_id,
      counterparty_id: counterparty_id,
      period_start: start,
      period_end: Date.end_of_month(start)
    }

    result =
      as_user(scope, fn ->
        with {:ok, link} <- Repo.insert(link), do: {:ok, Repo.get!(Link, link.id)}
      end)

    with {:ok, link} <- result, do: {:ok, token, link}
  end

  @doc "Live links for `party` in the group, newest first."
  def list_links(%Scope{} = scope, group_id, party) do
    as_user(scope, fn ->
      query =
        from l in Link,
          where: l.group_id == ^group_id and is_nil(l.revoked_at) and l.expires_at > ^now(),
          order_by: [desc: l.inserted_at]

      query =
        case party do
          {:user, id} -> where(query, [l], l.user_id == ^id)
          {:counterparty, id} -> where(query, [l], l.counterparty_id == ^id)
        end

      {:ok, Repo.all(query)}
    end)
  end

  @doc "Stops a link working. Anyone in the group can."
  def revoke_link(%Scope{} = scope, id) do
    as_user(scope, fn -> touched(set(Link, id, revoked_at: now())) end)
  end

  @doc """
  The statement behind `token`, as a map with string keys (see `read_statement`
  in the phase 3 migration), or `{:error, :invalid_statement}` for any link
  that doesn't work, whatever the reason.
  """
  def read(token) when is_binary(token) do
    Repo.as_nobody(fn ->
      case Repo.query("SELECT read_statement($1)", [token]) do
        {:ok, %{rows: [[statement]]}} -> statement
        {:error, _} -> Repo.rollback(:invalid_statement)
      end
    end)
  end

  def read(_), do: {:error, :invalid_statement}
end
