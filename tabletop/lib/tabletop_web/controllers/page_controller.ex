defmodule TabletopWeb.PageController do
  use TabletopWeb, :controller

  def about(conn, _params) do
    render(conn, :about)
  end

  def privacy(conn, _params) do
    render(conn, :privacy, page_title: "Privacy Policy")
  end

  def terms(conn, _params) do
    render(conn, :terms, page_title: "Terms of Service")
  end

  def code_of_conduct(conn, _params) do
    render(conn, :code_of_conduct, page_title: "Code of Conduct")
  end

  def health(conn, _params) do
    case Ecto.Adapters.SQL.query(Tabletop.Repo, "SELECT 1", []) do
      {:ok, _} -> send_resp(conn, 200, "OK")
      {:error, _} -> send_resp(conn, 503, "DB unavailable")
    end
  end
end
