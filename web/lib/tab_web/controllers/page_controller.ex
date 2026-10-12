defmodule TabWeb.PageController do
  use TabWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
