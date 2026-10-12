defmodule Tab.LedgerSQL do
  @moduledoc """
  Raw-SQL helpers for proving the database enforces the ledger's rules on its
  own. Everything here runs through `Tab.Repo.as_user/2` with plain SQL, never
  through the contexts, so a passing test means Postgres refused (or allowed)
  the action, not Elixir.

  People are user id strings. Counterparties in splits and payments are
  `{:counterparty, id}`.
  """

  alias Tab.Repo

  @doc "Runs one statement as `uid`. Returns `{:ok, result}` or `{:error, %Postgrex.Error{}}`."
  def run(uid, sql, params \\ []) do
    Repo.as_user(uid, fn ->
      case Repo.query(sql, dump_all(params)) do
        {:ok, result} -> result
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  def run!(uid, sql, params \\ []) do
    case run(uid, sql, params) do
      {:ok, result} -> load(result.rows)
      {:error, error} -> raise error
    end
  end

  @doc "Runs a statement as the connection owner (no person set; RLS bypassed)."
  def owner!(sql, params \\ []), do: load(Repo.query!(sql, dump_all(params)).rows)

  def person(email \\ nil) do
    attrs = if email, do: %{email: email}, else: %{}
    Tab.AccountsFixtures.user_fixture(attrs).id
  end

  def new_id, do: Ecto.UUID.generate()

  def create_group!(uid, name \\ "House") do
    id = new_id()
    run!(uid, "INSERT INTO groups (id, name) VALUES ($1, $2)", [id, name])
    id
  end

  @doc "Creates an invite as `admin` and returns the raw token."
  def invite!(admin, group_id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    run!(admin, "INSERT INTO invites (id, group_id, token_hash) VALUES ($1, $2, $3)", [
      new_id(),
      group_id,
      {:bytes, :crypto.hash(:sha256, token)}
    ])

    token
  end

  def join!(uid, group_id, admin) do
    token = invite!(admin, group_id)
    [[^group_id]] = run!(uid, "SELECT accept_invite($1)", [token])
    :ok
  end

  def counterparty!(uid, group_id, name) do
    id = new_id()

    run!(uid, "INSERT INTO counterparties (id, group_id, name) VALUES ($1, $2, $3)", [
      id,
      group_id,
      name
    ])

    id
  end

  def category_id(group_id, name) do
    [[id]] =
      owner!("SELECT id FROM categories WHERE group_id = $1 AND name = $2", [group_id, name])

    id
  end

  @doc """
  Adds an expense as `uid` with exact `shares` (`[{party, cents}]`), then forces
  the deferred shares-add-up check so errors show here, not at commit.
  """
  def expense!(uid, group_id, amount, shares, opts \\ []) do
    id = new_id()

    Repo.as_user(uid, fn ->
      Repo.query!(
        """
        INSERT INTO expenses (id, group_id, description, amount_cents, date, paid_by,
                              visibility, category_id, split)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        """,
        dump_all([
          id,
          group_id,
          Keyword.get(opts, :description, "Something"),
          amount,
          Keyword.get(opts, :date, ~D[2026-10-01]),
          Keyword.get(opts, :paid_by, uid),
          Keyword.get(opts, :visibility, "shared"),
          Keyword.get(opts, :category_id),
          %{"type" => "exact"}
        ])
      )

      Repo.query!("SELECT set_expense_shares($1, $2)", dump_all([id, shares_json(shares)]))
      check_shares!()
    end)
    |> case do
      {:ok, _} -> id
    end
  end

  def shares_json(shares) do
    Enum.map(shares, fn
      {{:counterparty, cp}, cents} -> %{"counterparty_id" => cp, "amount_cents" => cents}
      {user, cents} -> %{"user_id" => user, "amount_cents" => cents}
    end)
  end

  def check_shares! do
    Repo.query!("SET CONSTRAINTS expenses_shares_add_up, expense_shares_add_up IMMEDIATE")
    Repo.query!("SET CONSTRAINTS expenses_shares_add_up, expense_shares_add_up DEFERRED")
  end

  @doc "Records a payment as `uid`. Returns `{id, status}`."
  def payment!(uid, group_id, from, to, amount, opts \\ []) do
    id = new_id()
    {from_user, from_cp} = party(from)
    {to_user, to_cp} = party(to)

    run!(
      uid,
      """
      INSERT INTO payments (id, group_id, from_user_id, from_counterparty_id, to_user_id,
                            to_counterparty_id, amount_cents, date, method, category_id, status)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      """,
      [
        id,
        group_id,
        from_user,
        from_cp,
        to_user,
        to_cp,
        amount,
        Keyword.get(opts, :date, ~D[2026-10-05]),
        Keyword.get(opts, :method, "venmo"),
        Keyword.get(opts, :category_id),
        Keyword.get(opts, :status, "pending")
      ]
    )

    [[status]] = owner!("SELECT status FROM payments WHERE id = $1", [id])
    {id, status}
  end

  @doc "The group's balances as `uid` sees them: `[{debtor, creditor, cents}]`, sorted."
  def balances(uid, group_id) do
    run!(
      uid,
      "SELECT debtor_kind, debtor_id, creditor_kind, creditor_id, amount_cents FROM balances WHERE group_id = $1",
      [group_id]
    )
    |> Enum.map(fn [dk, d, ck, c, cents] -> {tag(dk, d), tag(ck, c), cents} end)
    |> Enum.sort()
  end

  def category_balances(uid, group_id) do
    run!(
      uid,
      """
      SELECT category_id, debtor_kind, debtor_id, creditor_kind, creditor_id, amount_cents
        FROM category_balances WHERE group_id = $1
      """,
      [group_id]
    )
    |> Enum.map(fn [cat, dk, d, ck, c, cents] -> {cat, tag(dk, d), tag(ck, c), cents} end)
    |> Enum.sort()
  end

  defp party({:counterparty, id}), do: {nil, id}
  defp party(user), do: {user, nil}

  defp tag("user", id), do: id
  defp tag("counterparty", id), do: {:counterparty, id}

  # UUID strings go in as 16-byte binaries; everything else as given.
  defp dump_all(params) do
    Enum.map(params, fn
      {:bytes, bin} ->
        bin

      value when is_binary(value) ->
        case Ecto.UUID.dump(value) do
          {:ok, bin} when byte_size(value) == 36 -> bin
          _ -> value
        end

      value ->
        value
    end)
  end

  defp load(nil), do: []

  defp load(rows) do
    Enum.map(rows, fn row ->
      Enum.map(row, fn
        <<_::128>> = bin -> if String.printable?(bin), do: bin, else: Ecto.UUID.load!(bin)
        value -> value
      end)
    end)
  end
end
