defmodule Tab.OAuthTest do
  @moduledoc "Pieces of Tab's OAuth server that need no database."
  use ExUnit.Case, async: true

  alias Tab.OAuth.RateLimit

  doctest Tab.OAuth
  doctest Tab.OAuth.CIMD

  test "loopback redirects match on any port; others exactly" do
    client = %Tab.OAuth.Client{
      redirect_uris: ["http://localhost/callback", "https://claude.ai/api/mcp/auth_callback"]
    }

    assert Tab.OAuth.redirect_matches?(client, "http://localhost:3118/callback")
    assert Tab.OAuth.redirect_matches?(client, "http://127.0.0.1:3118/callback")
    assert Tab.OAuth.redirect_matches?(client, "https://claude.ai/api/mcp/auth_callback")
    refute Tab.OAuth.redirect_matches?(client, "http://localhost:3118/other")
    refute Tab.OAuth.redirect_matches?(client, "https://claude.ai/api/mcp/auth_callback/x")
    refute Tab.OAuth.redirect_matches?(client, "http://evil.example:3118/callback")
  end

  test "the rate limit counts per window" do
    key = {:test, make_ref()}
    assert :ok = RateLimit.hit(key, 2, 60, 120)
    assert :ok = RateLimit.hit(key, 2, 60, 125)
    assert {:error, 55} = RateLimit.hit(key, 2, 60, 125)
    assert :ok = RateLimit.hit(key, 2, 60, 180)
  end
end
