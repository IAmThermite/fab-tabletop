defmodule TabletopWeb.ErrorHTMLTest do
  use TabletopWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    html = render_to_string(TabletopWeb.ErrorHTML, "404", "html", [])
    assert html =~ "Error 404"
    assert html =~ "Page Not Found"
    assert html =~ "Return to the lobby"
  end

  test "renders 500.html" do
    html = render_to_string(TabletopWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Error 500"
    assert html =~ "Return to the lobby"
  end
end
