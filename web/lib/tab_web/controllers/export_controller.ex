defmodule TabWeb.ExportController do
  @moduledoc """
  Everything you can see that you're part of, as one CSV: expenses you paid
  for or have a share in (private ones included), and payments to or from you.
  Read as you, so it holds exactly what the database lets you see.
  """
  use TabWeb, :controller

  alias Tab.{Groups, Ledger}

  @header ~w(group kind date description amount your_share paid_by from to method reference status category private edited deleted)

  def show(conn, _params) do
    scope = conn.assigns.current_scope

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="tab-#{Date.utc_today()}.csv")
    )
    |> send_resp(200, csv(scope))
  end

  @doc false
  def csv(scope) do
    me = scope.user.id
    {:ok, groups} = Groups.list_groups(scope)

    rows =
      Enum.flat_map(groups, fn group ->
        data = TabWeb.GroupData.load!(scope, group.id)
        {:ok, expenses} = Ledger.list_expenses(scope, group.id, include_deleted: true)
        {:ok, payments} = Ledger.list_payments(scope, group.id)

        expense_rows =
          for e <- expenses,
              share = Enum.find(e.shares, &(&1.user_id == me)),
              e.paid_by == me or share != nil do
            [
              group.name,
              "expense",
              Date.to_iso8601(e.date),
              e.description,
              cents(e.amount_cents),
              if(share, do: cents(share.amount_cents), else: "0.00"),
              TabWeb.GroupData.name_user(data, e.paid_by),
              "",
              "",
              "",
              "",
              "",
              TabWeb.GroupData.category_name(data, e.category_id) || "",
              yes(e.visibility == "private"),
              yes(e.edited_at),
              yes(e.deleted_at)
            ]
          end

        payment_rows =
          for p <- payments, me in [p.from_user_id, p.to_user_id] do
            [
              group.name,
              "payment",
              Date.to_iso8601(p.date),
              "",
              cents(p.amount_cents),
              "",
              "",
              TabWeb.GroupData.name(data, TabWeb.GroupData.from_party(p)),
              TabWeb.GroupData.name(data, TabWeb.GroupData.to_party(p)),
              p.method,
              p.reference || "",
              p.status,
              TabWeb.GroupData.category_name(data, p.category_id) || "",
              "",
              "",
              ""
            ]
          end

        expense_rows ++ payment_rows
      end)

    [@header | rows] |> Enum.map_join(&(Enum.map_join(&1, ",", fn v -> field(v) end) <> "\r\n"))
  end

  defp cents(n), do: :erlang.float_to_binary(n / 100, decimals: 2)
  defp yes(v), do: if(v, do: "yes", else: "")

  # Quote every field that needs it, and defuse spreadsheet formulas.
  defp field(v) do
    v = to_string(v)
    v = if String.starts_with?(v, ["=", "+", "-", "@", "\t", "\r"]), do: "'" <> v, else: v

    if String.contains?(v, [",", "\"", "\n", "\r"]),
      do: ~s(") <> String.replace(v, ~s("), ~s("")) <> ~s("),
      else: v
  end
end
