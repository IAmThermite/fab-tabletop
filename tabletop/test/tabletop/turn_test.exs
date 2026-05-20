defmodule Tabletop.TurnTest do
  use ExUnit.Case, async: false

  alias Tabletop.Turn

  setup do
    original = Application.get_env(:tabletop, Tabletop.Turn)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:tabletop, Tabletop.Turn)
  defp restore(value), do: Application.put_env(:tabletop, Tabletop.Turn, value)

  describe "ice_servers/1 without TURN configured" do
    test "returns STUN-only when secret/urls are unset" do
      Application.put_env(:tabletop, Tabletop.Turn, secret: nil, urls: [])

      servers = Turn.ice_servers("user-1")

      assert Enum.all?(servers, fn s -> String.starts_with?(s.urls, "stun:") end)
      refute Enum.any?(servers, &Map.has_key?(&1, :credential))
    end

    test "returns STUN-only when secret is an empty string" do
      Application.put_env(:tabletop, Tabletop.Turn, secret: "", urls: ["turn:localhost:3478"])

      servers = Turn.ice_servers("user-1")
      refute Enum.any?(servers, &Map.has_key?(&1, :credential))
    end
  end

  describe "ice_servers/1 with TURN configured" do
    setup do
      Application.put_env(:tabletop, Tabletop.Turn,
        secret: "test_secret",
        urls: ["turn:turn.example.com:3478"],
        ttl: 3600
      )

      :ok
    end

    test "appends a TURN entry with REST-API credentials" do
      servers = Turn.ice_servers("user-42")
      turn = List.last(servers)

      assert turn.urls == ["turn:turn.example.com:3478"]
      assert [expiry_str, "user-42"] = String.split(turn.username, ":")
      assert String.to_integer(expiry_str) > System.os_time(:second)
    end

    test "credential is the base64 HMAC-SHA1 of the username" do
      servers = Turn.ice_servers("user-42")
      turn = List.last(servers)

      expected = Base.encode64(:crypto.mac(:hmac, :sha, "test_secret", turn.username))
      assert turn.credential == expected
    end

    test "expiry honours the configured ttl" do
      before = System.os_time(:second)
      servers = Turn.ice_servers("user-42")
      turn = List.last(servers)

      [expiry_str, _] = String.split(turn.username, ":")
      expiry = String.to_integer(expiry_str)

      # ttl is 3600; allow a small window for clock movement during the test.
      assert expiry >= before + 3600
      assert expiry <= System.os_time(:second) + 3600 + 5
    end

    test "still includes the STUN servers first" do
      servers = Turn.ice_servers("user-42")
      assert [%{urls: "stun:" <> _}, %{urls: "stun:" <> _} | _] = servers
    end
  end
end
