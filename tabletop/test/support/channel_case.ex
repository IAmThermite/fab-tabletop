defmodule TabletopWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by channel tests.

  Such tests rely on `Phoenix.ChannelTest` and also import other functionality
  to make it easier to build common data structures and query the data layer.

  Finally, if the test case interacts with the database, we enable the SQL
  sandbox, so changes done to the database are reverted at the end of every
  test.

  The channel processes are spawned by `Phoenix.ChannelTest` rather than by the
  test, so they do not inherit the sandbox connection. Run channel tests with
  `async: false` — `Tabletop.DataCase.setup_sandbox/1` then puts the sandbox in
  shared mode, which is what lets a channel's `join/3` reach the Repo.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import TabletopWeb.ChannelCase

      alias Tabletop.Repo

      # The default endpoint for testing
      @endpoint TabletopWeb.Endpoint
    end
  end

  setup tags do
    Tabletop.DataCase.setup_sandbox(tags)
    :ok
  end
end
