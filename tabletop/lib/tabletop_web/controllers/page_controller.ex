defmodule TabletopWeb.PageController do
  use TabletopWeb, :controller

  def about(conn, _params) do
    render(conn, :about)
  end
end
