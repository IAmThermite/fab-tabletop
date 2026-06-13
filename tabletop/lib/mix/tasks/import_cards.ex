defmodule Mix.Tasks.ImportCards do
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("Running card import...")
    Tabletop.Cards.Importer.import_all()
    Mix.shell().info("Card import complete.")
  end
end
