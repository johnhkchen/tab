defmodule Tab.Repo do
  use Ecto.Repo,
    otp_app: :tab,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Runs `fun` inside a transaction that acts as one person, with row-level
  security in force.

  The transaction switches to the `tab_user` role (which can't bypass RLS) and
  sets `auth.uid()` to `user_id`. Every person-facing read and write — web, MCP,
  or anything else — should go through here, so the database, not the calling
  code, decides what that person can see and change.

  `via: "claude"` marks the transaction as coming through the MCP server; the
  database stamps it on new expenses and payments.
  """
  def as_user(user_id, fun, opts \\ []) when is_function(fun, 0) do
    user_id = Ecto.UUID.cast!(user_id)
    via = if opts[:via] == "claude", do: "claude", else: ""

    transaction(fn ->
      query!("SET LOCAL ROLE tab_user")
      query!("SELECT set_config('app.user_id', $1, true)", [user_id])
      query!("SELECT set_config('app.via', $1, true)", [via])
      result = fun.()

      # Committing ends the role switch on its own. Resetting here keeps a nested
      # (savepoint) transaction, like the test sandbox, from carrying it forward.
      # If `fun` raises, the rollback undoes the switch instead.
      query!("RESET ROLE")
      query!("SELECT set_config('app.user_id', '', true)")
      query!("SELECT set_config('app.via', '', true)")
      result
    end)
  end

  @doc """
  Runs `fun` as nobody: the `tab_user` role with no person set, so every
  policy refuses. For the few `SECURITY DEFINER` functions that check a token
  themselves, like `read_statement`.
  """
  def as_nobody(fun) when is_function(fun, 0) do
    transaction(fn ->
      query!("SET LOCAL ROLE tab_user")
      query!("SELECT set_config('app.user_id', '', true)")
      result = fun.()
      query!("RESET ROLE")
      result
    end)
  end
end
