defmodule Tabletop.Tournaments.NotAdminError do
  defexception message: "admin privileges required", plug_status: 403
end
