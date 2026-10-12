defmodule TabWeb.StatementHTML do
  use TabWeb, :html

  embed_templates "statement_html/*"

  def date(text) when is_binary(text), do: text |> Date.from_iso8601!() |> format_date()

  def month(text) when is_binary(text),
    do: text |> Date.from_iso8601!() |> Calendar.strftime("%B %Y")

  def method_label(m), do: method_name(m)
end
