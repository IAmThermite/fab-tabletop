# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Tabletop.Repo.insert!(%Tabletop.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.
alias Tabletop.Accounts
alias Tabletop.Accounts.{User, Scope}
alias Tabletop.Games
alias Tabletop.Games.Game
alias Tabletop.Repo

{:ok, user1} =
  Accounts.register_user(%{email: "user1@test.com", password: "password", name: "User 1"})

Repo.update(User.confirm_changeset(user1))

{:ok, user2} =
  Accounts.register_user(%{email: "user2@test.com", password: "password", name: "User 2"})

Repo.update(User.confirm_changeset(user2))

{:ok, user3} =
  Accounts.register_user(%{email: "user3@test.com", password: "password", name: "User 3"})

Repo.update(User.confirm_changeset(user3))

user1_scope = Scope.for_user(user1)
user2_scope = Scope.for_user(user2)

{:ok, _game1} =
  Games.create_game(user1_scope, %{
    title: "Game 1",
    description: "A test game created by user 1",
    format: :classic_constructed
  })

{:ok, _game2} =
  Games.create_game(user2_scope, %{
    title: "Game 2",
    description: "A test game created by user 2",
    format: :silver_age
  })

# populate card database
Tabletop.Cards.Importer.import_from_generated_data()
