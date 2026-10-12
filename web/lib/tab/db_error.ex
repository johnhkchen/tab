defmodule Tab.DBError do
  @moduledoc """
  Turns the database's refusals into plain results. The database is where the
  rules are enforced; this only names what it said.
  """

  @type reason ::
          :forbidden
          | :invalid_invite
          | :already_member
          | :unsettled
          | :override_overlap
          | :invalid_statement
          | {:invalid, String.t()}

  @spec reason(Postgrex.Error.t()) :: reason | nil
  def reason(%Postgrex.Error{postgres: %{code: :insufficient_privilege}}), do: :forbidden
  def reason(%Postgrex.Error{postgres: %{hint: "invalid_invite"}}), do: :invalid_invite
  def reason(%Postgrex.Error{postgres: %{hint: "already_member"}}), do: :already_member
  def reason(%Postgrex.Error{postgres: %{hint: "unsettled"}}), do: :unsettled
  def reason(%Postgrex.Error{postgres: %{hint: "override_overlap"}}), do: :override_overlap
  def reason(%Postgrex.Error{postgres: %{hint: "invalid_statement"}}), do: :invalid_statement

  def reason(%Postgrex.Error{postgres: %{code: code, message: message}})
      when code in [
             :check_violation,
             :foreign_key_violation,
             :unique_violation,
             :not_null_violation
           ],
      do: {:invalid, message}

  def reason(_), do: nil

  @doc """
  Runs `fun` as the scope's person (see `Tab.Repo.as_user/2`). `fun` returns
  `{:ok, value}` or `{:error, reason}`; an error rolls everything back. A
  refusal from the database comes back as `{:error, reason}` instead of raising.
  """
  def as_user(%Tab.Accounts.Scope{user: %{id: user_id}}, fun) do
    Tab.Repo.as_user(user_id, fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Tab.Repo.rollback(reason)
      end
    end)
  rescue
    e in Postgrex.Error ->
      case reason(e) do
        nil -> reraise e, __STACKTRACE__
        reason -> {:error, reason}
      end
  end
end
