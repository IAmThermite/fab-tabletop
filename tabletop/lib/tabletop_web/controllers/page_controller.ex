defmodule TabletopWeb.PageController do
  use TabletopWeb, :controller

  def about(conn, _params) do
    render(conn, :about)
  end

  def health(conn, _params) do
    case Ecto.Adapters.SQL.query(Tabletop.Repo, "SELECT 1", []) do
      {:ok, _} -> send_resp(conn, 200, "OK")
      {:error, _} -> send_resp(conn, 503, "DB unavailable")
    end
  end
end
