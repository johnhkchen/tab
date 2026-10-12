defmodule Tab.Groups do
  @moduledoc """
  Groups, who's in them, invites, counterparties, and categories.

  Every function takes the current person's `%Tab.Accounts.Scope{}` and runs as
  them through `Tab.Repo.as_user/2`, so row-level security decides what they
  can see and change. Nothing here checks permissions itself.
  """
  import Ecto.Query

  alias Tab.Accounts.Scope
  alias Tab.Groups.{Category, Counterparty, Group, Invite, Membership}
  alias Tab.Repo

  import Tab.DBError, only: [as_user: 2]

  @invite_days 7

  ## Groups

  @doc "The groups this person is in, archived ones last."
  def list_groups(%Scope{} = scope) do
    as_user(scope, fn ->
      {:ok, Repo.all(from g in Group, order_by: [asc_nulls_first: g.deleted_at, asc: g.name])}
    end)
  end

  def get_group(%Scope{} = scope, id) do
    as_user(scope, fn -> found(Repo.get(Group, id)) end)
  end

  @doc "Makes a group. The database makes its creator the admin and adds the starter categories."
  def create_group(%Scope{} = scope, attrs) do
    as_user(scope, fn ->
      with {:ok, group} <- Repo.insert(Group.changeset(%Group{}, attrs)) do
        {:ok, Repo.get!(Group, group.id)}
      end
    end)
  end

  def rename_group(%Scope{} = scope, id, name) do
    as_user(scope, fn ->
      with {:ok, group} <- found(Repo.get(Group, id)) do
        group |> Group.changeset(%{name: name}) |> update()
      end
    end)
  end

  @doc """
  Archives a group (admins only). Nothing is deleted: members can still read
  and export it, but nothing in it can change until an admin unarchives it.
  Check `Tab.Ledger.balances/2` first to warn when someone still owes money.
  """
  def archive_group(%Scope{} = scope, id) do
    as_user(scope, fn -> touched(set(Group, id, deleted_at: now())) end)
  end

  def unarchive_group(%Scope{} = scope, id) do
    as_user(scope, fn -> touched(set(Group, id, deleted_at: nil)) end)
  end

  ## Members

  @doc "The group's current members, with their profiles."
  def list_members(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from m in Membership,
           where: m.group_id == ^group_id and is_nil(m.left_at),
           order_by: [m.joined_at, m.role],
           preload: :profile
       )}
    end)
  end

  @doc """
  Leaves a group. You have to be even with everyone first (`{:error,
  :unsettled}` otherwise). History stays with the group; you lose access to it.
  """
  def leave_group(%Scope{user: user} = scope, group_id),
    do: end_membership(scope, group_id, user.id)

  @doc """
  Removes someone from a group (admins only), even if they aren't even. What
  they owe or are owed stays in the balances, and payments with them still
  count as soon as they're recorded.
  """
  def remove_member(%Scope{} = scope, group_id, user_id),
    do: end_membership(scope, group_id, user_id)

  defp end_membership(scope, group_id, user_id) do
    as_user(scope, fn ->
      from(m in Membership,
        where: m.group_id == ^group_id and m.user_id == ^user_id and is_nil(m.left_at)
      )
      |> Repo.update_all(set: [left_at: now(), updated_at: now()])
      |> touched()
    end)
  end

  @doc "Makes someone an admin or a member (admins only)."
  def set_role(%Scope{} = scope, group_id, user_id, role) when role in ~w(admin member) do
    as_user(scope, fn ->
      from(m in Membership,
        where: m.group_id == ^group_id and m.user_id == ^user_id and is_nil(m.left_at)
      )
      |> Repo.update_all(set: [role: role, updated_at: now()])
      |> touched()
    end)
  end

  ## Invites

  @doc """
  Makes a single-use invite (admins only). Returns the raw token, which goes in
  the link and is never stored; the database keeps only its hash.
  """
  def create_invite(%Scope{} = scope, group_id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    invite = %Invite{
      group_id: group_id,
      token_hash: :crypto.hash(:sha256, token),
      expires_at: DateTime.add(now(), @invite_days, :day)
    }

    as_user(scope, fn ->
      with {:ok, invite} <- Repo.insert(invite), do: {:ok, {token, invite}}
    end)
  end

  @doc "Joins the invite's group. Returns `{:ok, group_id}`, or `{:error, :invalid_invite | :already_member}`."
  def accept_invite(%Scope{} = scope, token) when is_binary(token) do
    as_user(scope, fn ->
      %{rows: [[group_id]]} = Repo.query!("SELECT accept_invite($1)", [token])
      Ecto.UUID.load(group_id)
    end)
  end

  def list_invites(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from i in Invite,
           where: i.group_id == ^group_id and is_nil(i.used_at) and is_nil(i.revoked_at),
           where: i.expires_at > ^now(),
           order_by: [desc: i.inserted_at]
       )}
    end)
  end

  def revoke_invite(%Scope{} = scope, invite_id) do
    as_user(scope, fn -> touched(set(Invite, invite_id, revoked_at: now())) end)
  end

  ## Counterparties

  def list_counterparties(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from c in Counterparty,
           where: c.group_id == ^group_id and is_nil(c.deleted_at),
           order_by: c.name
       )}
    end)
  end

  def create_counterparty(%Scope{} = scope, group_id, attrs) do
    as_user(scope, fn ->
      %Counterparty{group_id: group_id} |> Counterparty.changeset(attrs) |> Repo.insert()
    end)
  end

  def update_counterparty(%Scope{} = scope, id, attrs) do
    as_user(scope, fn ->
      with {:ok, cp} <- found(Repo.get(Counterparty, id)) do
        cp |> Counterparty.changeset(attrs) |> update()
      end
    end)
  end

  def archive_counterparty(%Scope{} = scope, id) do
    as_user(scope, fn -> touched(set(Counterparty, id, deleted_at: now())) end)
  end

  ## Categories

  def list_categories(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from c in Category,
           where: c.group_id == ^group_id and is_nil(c.deleted_at),
           order_by: c.name
       )}
    end)
  end

  def create_category(%Scope{} = scope, group_id, name) do
    as_user(scope, fn ->
      %Category{group_id: group_id} |> Category.changeset(%{name: name}) |> Repo.insert()
    end)
  end

  def rename_category(%Scope{} = scope, id, name) do
    as_user(scope, fn ->
      with {:ok, category} <- found(Repo.get(Category, id)) do
        category |> Category.changeset(%{name: name}) |> update()
      end
    end)
  end

  def archive_category(%Scope{} = scope, id) do
    as_user(scope, fn -> touched(set(Category, id, deleted_at: now())) end)
  end

  ## Helpers shared with Tab.Ledger

  @doc false
  def now, do: DateTime.utc_now(:second)

  @doc false
  def found(nil), do: {:error, :not_found}
  def found(record), do: {:ok, record}

  @doc false
  # Updates that row-level security filters out touch no rows; say so.
  def update(changeset) do
    Repo.update(changeset, stale_error_field: :id, stale_error_message: "you can't change this")
  end

  @doc false
  def set(schema, id, fields) do
    from(r in schema, where: r.id == ^id)
    |> Repo.update_all(set: Keyword.put(fields, :updated_at, now()))
  end

  @doc false
  def touched({0, _}), do: {:error, :not_found}
  def touched({_, _}), do: {:ok, :done}
end
