defmodule Tabletop.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Tabletop.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias Tabletop.Accounts.User

  defstruct user: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Returns true if the scope's user is listed in `:admin_ids` config.
  """
  def admin?(%__MODULE__{user: %User{id: id}}) when is_binary(id) do
    id in Application.get_env(:tabletop, :admin_ids, [])
  end

  def admin?(_), do: false

  @doc """
  Returns true if the scope's user id is listed in `:live_dashboard_user_ids`.

  Kept deliberately separate from `admin?/1`: both are id lists, but tournament
  admin and BEAM introspection are different privileges, so being one does not
  make you the other.

  Unlike `admin?/1`, comparison is case-insensitive. `user.id` is always a
  lowercase UUID, but the configured list is hand-written into an env var, so
  an id pasted in uppercase would otherwise silently fail to match.
  """
  def live_dashboard?(%__MODULE__{user: %User{id: id}}) when is_binary(id) do
    target = String.downcase(id)

    :tabletop
    |> Application.get_env(:live_dashboard_user_ids, [])
    |> Enum.any?(&(is_binary(&1) and String.downcase(&1) == target))
  end

  def live_dashboard?(_), do: false
end
