defmodule Tabletop.Fab.EffectsTest do
  use ExUnit.Case, async: true

  alias Tabletop.Fab.Effects

  describe "tokens/0" do
    test "token names are unique" do
      # `GameState.proxy_tokens` is keyed by token *name*, and the proxy-token
      # picker offers the whole catalogue, so two entries sharing a name would
      # collide into one counter and render arbitrarily.
      names = Enum.map(Effects.tokens(), fn {_key, token} -> token.name end)

      assert names == Enum.uniq(names)
    end

    test "every token declares for_opponent" do
      assert Enum.all?(Effects.tokens(), fn {_key, token} -> is_boolean(token.for_opponent) end)
    end
  end

  describe "proxy_token_list/0" do
    test "offers every token, opponent-inflicted debuffs first" do
      list = Effects.proxy_token_list()

      assert length(list) == map_size(Effects.tokens())

      # `false < true`, so a descending sort is "every debuff, then the rest".
      flags = Enum.map(list, fn {_key, token} -> token.for_opponent end)
      assert flags == Enum.sort(flags, :desc)
    end

    test "sorts alphabetically within each group" do
      {debuffs, rest} =
        Effects.proxy_token_list()
        |> Enum.map(fn {_key, token} -> {token.for_opponent, token.name} end)
        |> Enum.split_with(fn {for_opponent, _name} -> for_opponent end)

      debuff_names = Enum.map(debuffs, &elem(&1, 1))
      rest_names = Enum.map(rest, &elem(&1, 1))

      assert debuff_names == Enum.sort(debuff_names)
      assert rest_names == Enum.sort(rest_names)
    end
  end

  describe "tokens_for_player/0" do
    test "excludes opponent-inflicted debuffs" do
      names = Enum.map(Effects.tokens_for_player(), fn {_key, token} -> token.name end)

      assert "Runechant" in names
      refute "Mark" in names
      refute "Frostbite" in names
    end
  end

  describe "singleton_token?/1" do
    test "only Mark is capped at one" do
      assert Effects.singleton_token?("Mark")
      refute Effects.singleton_token?("Frostbite")
      refute Effects.singleton_token?("Nonsense")
    end
  end
end
