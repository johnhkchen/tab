defmodule TabWeb.FormatTest do
  use ExUnit.Case, async: true
  import TabWeb.Format

  test "formats cents" do
    assert money(0) == "$0.00"
    assert money(5) == "$0.05"
    assert money(123_456) == "$1,234.56"
    assert money(-2_500) == "−$25.00"
  end

  test "reads what people type" do
    assert parse_money("12") == {:ok, 1_200}
    assert parse_money("12.5") == {:ok, 1_250}
    assert parse_money(" $1,200.05 ") == {:ok, 120_005}
    assert parse_money(".99") == :error
    assert parse_money("0.99") == {:ok, 99}
    assert parse_money("1.005") == :error
    assert parse_money("-3") == :error
    assert parse_money("ten") == :error
  end

  test "editing fields" do
    assert amount_input(1_250) == "12.50"
    assert amount_input(nil) == ""
  end
end
