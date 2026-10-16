defmodule Tab.TestResolver do
  @moduledoc "Resolves `*.example` to a public address for tests; anything else for real."
  def resolve(host) do
    if String.ends_with?(to_string(host), ".example"),
      do: {:ok, [{93, 184, 216, 34}]},
      else: Tab.OAuth.CIMD.resolve(host)
  end
end
