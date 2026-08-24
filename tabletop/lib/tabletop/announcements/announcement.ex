defmodule Tabletop.Announcements.Announcement do
  @moduledoc """
  A site-wide message shown to every visitor for a window of time — scheduled
  downtime being the motivating case.

  The display window is a pair of absolute timestamps. `starts_at` defaults to
  "now" so publishing is a one-field action; `ends_at` is optional and `nil`
  means "until an admin clears it". Admins pick the end as a duration rather
  than a wall-clock time (see the virtual `duration_minutes`), which sidesteps
  the browser-vs-server timezone dance for what is nearly always a relative
  decision ("put this up for the next hour").
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @levels [:info, :warning, :critical]

  # Offered by the admin form. `nil` (the "Until I clear it" option) leaves
  # `ends_at` unset.
  @durations [
    {"Until I clear it", ""},
    {"15 minutes", "15"},
    {"1 hour", "60"},
    {"4 hours", "240"},
    {"24 hours", "1440"}
  ]

  @max_message_length 500

  schema "announcements" do
    field :message, :string
    field :level, Ecto.Enum, values: @levels, default: :info
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :dismissible, :boolean, default: true

    # Form-facing window length; the changeset derives `ends_at` from it. Blank
    # means an open-ended announcement.
    field :duration_minutes, :integer, virtual: true

    belongs_to :created_by, Tabletop.Accounts.User, type: Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  def levels, do: @levels

  def level_options do
    [
      {"Info — neutral notice", :info},
      {"Warning — action may be needed", :warning},
      {"Critical — service affecting", :critical}
    ]
  end

  def duration_options, do: @durations

  @doc """
  Builds an announcement changeset. The `scope` stamps `created_by_id` on
  insert; pass `nil` for announcements published from a remote console, which
  have no user behind them.
  """
  def changeset(announcement, attrs, scope \\ nil) do
    announcement
    |> cast(attrs, [:message, :level, :starts_at, :ends_at, :dismissible, :duration_minutes])
    |> validate_required([:message, :level])
    |> validate_length(:message, min: 1, max: @max_message_length)
    |> put_default_starts_at()
    |> put_ends_at_from_duration(attrs)
    |> validate_window()
    |> put_creator(scope)
  end

  defp put_default_starts_at(changeset) do
    case get_field(changeset, :starts_at) do
      nil -> put_change(changeset, :starts_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  # A supplied duration always wins over any `ends_at` already on the struct —
  # re-saving with a fresh duration should restart the window rather than
  # silently keep the old expiry, and picking "Until I clear it" should clear
  # it. Read from the raw attrs rather than the changeset because `cast/3`
  # turns the blank option into `nil`, which is indistinguishable from "the
  # caller never mentioned a duration" (the `publish!/2` and API paths).
  defp put_ends_at_from_duration(changeset, attrs) do
    case fetch_duration(attrs) do
      :absent ->
        changeset

      {:ok, nil} ->
        put_change(changeset, :ends_at, nil)

      {:ok, minutes} when minutes > 0 ->
        starts_at = get_field(changeset, :starts_at)
        put_change(changeset, :ends_at, DateTime.add(starts_at, minutes * 60, :second))

      _ ->
        add_error(changeset, :duration_minutes, "must be a positive number of minutes")
    end
  end

  defp fetch_duration(attrs) when is_map(attrs) do
    case {Map.fetch(attrs, "duration_minutes"), Map.fetch(attrs, :duration_minutes)} do
      {{:ok, value}, _} -> parse_duration(value)
      {_, {:ok, value}} -> parse_duration(value)
      _ -> :absent
    end
  end

  defp fetch_duration(_attrs), do: :absent

  defp parse_duration(nil), do: {:ok, nil}
  defp parse_duration(""), do: {:ok, nil}
  defp parse_duration(value) when is_integer(value), do: {:ok, value}

  defp parse_duration(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {minutes, ""} -> {:ok, minutes}
      _ -> :error
    end
  end

  defp parse_duration(_value), do: :error

  defp validate_window(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(ends_at, starts_at) != :gt do
      add_error(changeset, :ends_at, "must be after the start time")
    else
      changeset
    end
  end

  defp put_creator(changeset, %{user: %{id: id}}), do: put_change(changeset, :created_by_id, id)
  defp put_creator(changeset, _scope), do: changeset
end
