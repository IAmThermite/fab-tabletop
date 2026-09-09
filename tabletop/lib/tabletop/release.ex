defmodule Tabletop.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :tabletop

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @import_options [:source, :replace_all, :allow_missing_phashes]

  @doc """
  Seeds the card database from the data set bundled into the release.

  Takes `Tabletop.Cards.Importer.import_all/1`'s options, so a release can reach
  them without a Mix environment:

      bin/tabletop eval 'Tabletop.Release.import_cards()'
      bin/tabletop eval 'Tabletop.Release.import_cards(replace_all: true)'

  Supported: #{inspect(@import_options)}.
  """
  def import_cards(opts \\ []) do
    validate_import_options!(opts)
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          Tabletop.Cards.Importer.import_all(opts)
        end)
    end
  end

  # Checked before `load_app/0` so a typo fails immediately and without side
  # effects. Worth doing: these are typed by hand into a production shell, and an
  # ignored `replace_al: true` looks exactly like a `replace_all` that had nothing
  # to clear — the same silent-success failure mode the importer's own pHash guard
  # exists to prevent.
  defp validate_import_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "import_cards/1 expects a keyword list, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @import_options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown import option(s): #{inspect(unknown)}. " <>
                "Supported: #{inspect(@import_options)}"
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
