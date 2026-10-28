defmodule Tabletop.NotAdminError do
  @moduledoc """
  Raised by context functions guarded on `Tabletop.Accounts.Scope.admin?/1`.

  App-level rather than context-level: admin is one privilege (membership in
  `:admin_ids`), not a per-context one, so any admin-guarded context raises
  the same thing.
  """
  defexception message: "admin privileges required", plug_status: 403
end
