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
  """
  def as_user(user_id, fun) when is_function(fun, 0) do
    user_id = Ecto.UUID.cast!(user_id)

    transaction(fn ->
      query!("SET LOCAL ROLE tab_user")
      query!("SELECT set_config('app.user_id', $1, true)", [user_id])
      result = fun.()

      # Committing ends the role switch on its own. Resetting here keeps a nested
      # (savepoint) transaction, like the test sandbox, from carrying it forward.
      # If `fun` raises, the rollback undoes the switch instead.
      query!("RESET ROLE")
      query!("SELECT set_config('app.user_id', '', true)")
      result
    end)
  end
end
