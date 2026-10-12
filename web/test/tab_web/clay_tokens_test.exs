defmodule TabWeb.ClayTokensTest do
  @moduledoc """
  Phase 2 test 5, the source half: no colors outside the clay kit's tokens.
  Tailwind's default palette is switched off in app.css, so a class like
  `bg-red-500` wouldn't render anyway; this keeps hex codes, rgb(), inline
  color styles, and palette class names out of the templates too. (The 360 px
  half is checked in a real browser: `mise run check:narrow`.)
  """
  use ExUnit.Case, async: true

  @palette ~w(slate gray zinc neutral stone red orange amber yellow lime green emerald teal
              cyan sky blue indigo violet purple fuchsia pink rose white black)

  defp sources do
    Path.wildcard("lib/tab_web/**/*.{ex,heex}") -- Path.wildcard("lib/tab_web/controllers/dev/*")
  end

  test "templates use only kit colors" do
    palette_class =
      ~r/\b(?:bg|text|border|ring|fill|stroke|from|to|via|outline|divide|shadow|accent|decoration)-(?:#{Enum.join(@palette, "|")})(?:-\d{2,3})?\b/

    offenders =
      for path <- sources(),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          (Regex.match?(~r/#[0-9a-fA-F]{3,8}\b(?![\w{])/, line) and
             not Regex.match?(~r/~p"|href=|navigate=|"#|\#{/, line)) or
            Regex.match?(~r/rgba?\(|hsla?\(|oklch\(/, line) or
            Regex.match?(palette_class, line) or
            Regex.match?(~r/style="[^"]*color/, line) do
        "#{path}:#{n}: #{String.trim(line)}"
      end

    assert offenders == [], "colors outside the kit:\n" <> Enum.join(offenders, "\n")
  end

  test "app.css turns off Tailwind's default palette" do
    css = File.read!("assets/css/app.css")
    assert css =~ "--color-*: initial;"
  end
end
