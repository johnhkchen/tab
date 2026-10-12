defmodule TabWeb.LiveHelpers do
  @moduledoc "Small formatting helpers shared by the pages."

  @methods %{
    "venmo" => "Venmo",
    "zelle" => "Zelle",
    "cashapp" => "Cash App",
    "paypal" => "PayPal",
    "cash" => "cash",
    "check" => "check",
    "other" => "another way"
  }

  def method_name(kind), do: Map.get(@methods, kind, kind)

  def method_options do
    [{"Venmo", "venmo"}, {"Zelle", "zelle"}, {"Cash App", "cashapp"}, {"PayPal", "paypal"}] ++
      [{"Cash", "cash"}, {"Check", "check"}, {"Another way", "other"}]
  end

  def status_label("pending"), do: "waiting for them to confirm"
  def status_label("confirmed"), do: "confirmed"
  def status_label("self_attested"), do: "counted"
  def status_label("declined"), do: "didn't arrive"

  def format_date(%Date{} = d), do: Calendar.strftime(d, "%b %-d, %Y")
  def format_date(%DateTime{} = d), do: Calendar.strftime(d, "%b %-d, %Y")
end
