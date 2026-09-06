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

    test "expiry is at least the configured ttl away, and at most ttl + window" do
      before = System.os_time(:second)
      servers = Turn.ice_servers("user-42")

      expiry = expiry_of(List.last(servers))

      # The expiry is rounded up to the next window boundary before ttl is
      # added, so it lands in [now + ttl, now + ttl + window].
      assert expiry >= before + 3600
      assert expiry <= System.os_time(:second) + 3600 + 3600
    end

    test "expiry lands exactly on a window boundary plus the ttl" do
      expiry = expiry_of(List.last(Turn.ice_servers("user-42")))

      assert rem(expiry - 3600, 3600) == 0
    end

    test "the same user gets the same credential within a window" do
      # coturn keys user-quota on the literal username, so this stability is
      # what makes the quota bind to a person rather than to a page load.
      first = List.last(Turn.ice_servers("user-42"))
      second = List.last(Turn.ice_servers("user-42"))

      assert first.username == second.username
      assert first.credential == second.credential
    end

    test "different users get different credentials in the same window" do
      a = List.last(Turn.ice_servers("user-1"))
      b = List.last(Turn.ice_servers("user-2"))

      refute a.username == b.username
      refute a.credential == b.credential
    end

    test "a window of 0 disables quantisation" do
      Application.put_env(:tabletop, Tabletop.Turn,
        secret: "test_secret",
        urls: ["turn:turn.example.com:3478"],
        ttl: 3600,
        window: 0
      )

      before = System.os_time(:second)
      expiry = expiry_of(List.last(Turn.ice_servers("user-42")))

      assert expiry >= before + 3600
      assert expiry <= System.os_time(:second) + 3600 + 5
    end

    test "still includes the STUN servers first" do
      servers = Turn.ice_servers("user-42")
      assert [%{urls: "stun:" <> _}, %{urls: "stun:" <> _} | _] = servers
    end
  end

  defp expiry_of(%{username: username}) do
    [expiry_str, _user_id] = String.split(username, ":")
    String.to_integer(expiry_str)
  end
end
