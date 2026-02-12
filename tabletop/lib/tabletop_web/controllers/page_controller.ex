defmodule TabletopWeb.PageController do
  use TabletopWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
