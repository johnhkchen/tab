defmodule TabWeb.PageController do
  use TabWeb, :controller

  # Signed in, the front door is your groups.
  def home(%{assigns: %{current_scope: %{user: %{}}}} = conn, _params) do
    redirect(conn, to: ~p"/groups")
  end

  def home(conn, _params) do
    render(conn, :home)
  end
end
