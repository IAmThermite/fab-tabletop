defmodule Tabletop.HeroesTest do
  use ExUnit.Case, async: true

  alias Tabletop.Heroes
  alias Tabletop.Heroes.Hero

  @formats [:classic_constructed, :blitz, :silver_age, :living_legend]

  describe "all/0" do
    test "returns the roster as Hero structs, ordered by name" do
      heroes = Heroes.all()

      assert length(heroes) > 0
      assert Enum.all?(heroes, &match?(%Hero{}, &1))
      assert Enum.all?(heroes, &(is_binary(&1.slug) and is_binary(&1.name)))
      assert heroes == Enum.sort_by(heroes, & &1.name)
    end
  end

  describe "get/1" do
    test "looks up by slug" do
      sample = hd(Heroes.all())
      assert Heroes.get(sample.slug) == sample
    end

    test "is nil for unknown or non-binary input" do
      assert Heroes.get("does-not-exist") == nil
      assert Heroes.get(nil) == nil
      assert Heroes.get(:atom) == nil
    end
  end

  describe "legal_for/1" do
    test "returns exactly the heroes legal in the format, ordered by name" do
      for format <- @formats do
        legal = Heroes.legal_for(format)
        expected = Enum.filter(Heroes.all(), &(format in &1.formats))

        assert legal == expected
        assert Enum.all?(legal, &(format in &1.formats))
        assert legal == Enum.sort_by(legal, & &1.name)
      end
    end
  end

  describe "legal?/2" do
    test "agrees with legal_for/1" do
      format = :classic_constructed

      assert Enum.all?(Heroes.legal_for(format), &Heroes.legal?(&1.slug, format))

      illegal = Enum.find(Heroes.all(), &(format not in &1.formats))
      if illegal, do: refute(Heroes.legal?(illegal.slug, format))
    end

    test "is false for an unknown hero" do
      refute Heroes.legal?("nope", :classic_constructed)
    end
  end

  describe "options_for/1" do
    test "returns {name, slug} pairs for legal heroes" do
      options = Heroes.options_for(:blitz)
      legal = Heroes.legal_for(:blitz)

      assert options == Enum.map(legal, &{&1.name, &1.slug})
    end
  end

  describe "icon_path/1" do
    test "builds the served path" do
      assert Heroes.icon_path("hala-bladesaint-of-the-vow") ==
               "/images/heroes/hala-bladesaint-of-the-vow.png"
    end
  end

  test "every hero has an avatar PNG on disk" do
    dir = Application.app_dir(:tabletop, "priv/static/images/heroes")

    for hero <- Heroes.all() do
      path = Path.join(dir, hero.slug <> ".png")
      assert File.exists?(path), "missing avatar for #{hero.slug} (#{path})"
    end
  end
end
