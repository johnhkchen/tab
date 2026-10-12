defmodule TabWeb.GroupData do
  @moduledoc """
  Everything a group page needs to show names: the group, its members (with
  profiles), counterparties, and categories, loaded as the signed-in person.

  Someone who isn't in the group gets a plain 404, the same as for a group that
  doesn't exist, so a URL never reveals a group's name.
  """
  alias Tab.{Groups, Ledger}

  defmodule NotFound do
    defexception message: "not found", plug_status: 404
  end

  defstruct [
    :group,
    :me,
    :admin?,
    :archived?,
    members: [],
    counterparties: [],
    categories: [],
    names: %{}
  ]

  def load!(scope, group_id) do
    with {:ok, _} <- Ecto.UUID.cast(group_id),
         {:ok, group} <- Groups.get_group(scope, group_id),
         {:ok, members} <- Groups.list_members(scope, group_id),
         {:ok, counterparties} <- Groups.list_counterparties(scope, group_id),
         {:ok, categories} <- Groups.list_categories(scope, group_id) do
      me = scope.user.id

      names =
        Map.new(members, &{{:user, &1.user_id}, display_name(&1, me)})
        |> Map.merge(Map.new(counterparties, &{{:counterparty, &1.id}, &1.name}))

      %__MODULE__{
        group: group,
        me: me,
        admin?: Enum.any?(members, &(&1.user_id == me and &1.role == "admin")),
        archived?: group.deleted_at != nil,
        members: members,
        counterparties: counterparties,
        categories: categories,
        names: names
      }
    else
      _ -> raise NotFound
    end
  end

  defp display_name(%{user_id: me}, me), do: "You"
  defp display_name(%{profile: %{display_name: name}}, _), do: name
  defp display_name(_, _), do: "Someone"

  @doc "A party's name: `You`, a member's display name, a counterparty, or `A former member`."
  def name(%__MODULE__{names: names}, party), do: Map.get(names, party, "A former member")

  def name_user(data, id), do: name(data, {:user, id})

  def category_name(%__MODULE__{categories: cats}, id) do
    Enum.find_value(cats, fn c -> c.id == id && c.name end)
  end

  @doc "Select options for every party in the group: members first, then counterparties."
  def party_options(%__MODULE__{} = data) do
    Enum.map(data.members, &{name_user(data, &1.user_id), "user:" <> &1.user_id}) ++
      Enum.map(data.counterparties, &{&1.name, "counterparty:" <> &1.id})
  end

  def parse_party("user:" <> id), do: {:user, id}
  def parse_party("counterparty:" <> id), do: {:counterparty, id}
  def parse_party(_), do: nil

  def party_key({:user, id}), do: "user:" <> id
  def party_key({:counterparty, id}), do: "counterparty:" <> id

  @doc "The party a payment's from or to."
  def from_party(p),
    do:
      if(p.from_user_id,
        do: {:user, p.from_user_id},
        else: {:counterparty, p.from_counterparty_id}
      )

  def to_party(p),
    do: if(p.to_user_id, do: {:user, p.to_user_id}, else: {:counterparty, p.to_counterparty_id})

  def share_party(s),
    do: if(s.user_id, do: {:user, s.user_id}, else: {:counterparty, s.counterparty_id})

  @doc "Reloads the group's balances for the page."
  def balances(scope, %__MODULE__{group: group}) do
    {:ok, balances} = Ledger.balances(scope, group.id)
    balances
  end
end
