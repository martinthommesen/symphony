defmodule SymphonyElixir.Observability.ControlTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Observability.Control

  describe "authenticate/1" do
    setup do
      original = System.get_env("SYMPHONY_CONTROL_TOKEN")
      on_exit(fn -> if original, do: System.put_env("SYMPHONY_CONTROL_TOKEN", original), else: System.delete_env("SYMPHONY_CONTROL_TOKEN") end)
      :ok
    end

    test "returns :read_only when no token configured" do
      System.delete_env("SYMPHONY_CONTROL_TOKEN")
      assert Control.authenticate("anything") == :read_only
    end

    test "returns :ok on exact match" do
      System.put_env("SYMPHONY_CONTROL_TOKEN", "secret-token-value")
      assert Control.authenticate("secret-token-value") == :ok
    end

    test "rejects mismatched token" do
      System.put_env("SYMPHONY_CONTROL_TOKEN", "secret-token-value")
      assert Control.authenticate("wrong-token") == {:error, :invalid_token}
    end

    test "missing token returns missing_token" do
      System.put_env("SYMPHONY_CONTROL_TOKEN", "secret-token-value")
      assert Control.authenticate(nil) == {:error, :missing_token}
    end

    test "different-length token returns invalid_token" do
      System.put_env("SYMPHONY_CONTROL_TOKEN", "secret")
      assert Control.authenticate("differentlength") == {:error, :invalid_token}
    end

    test "whitespace-only env var is treated as no token (control disabled)" do
      System.put_env("SYMPHONY_CONTROL_TOKEN", "   ")
      assert Control.configured_token() == nil
      assert Control.control_enabled?() == false
      # An empty Bearer token must not authenticate when control is disabled.
      assert Control.authenticate("") == :read_only
    end

    test "empty string env var is treated as no token" do
      System.put_env("SYMPHONY_CONTROL_TOKEN", "")
      assert Control.configured_token() == nil
    end
  end

  describe "extract_bearer/1" do
    test "extracts the token from a Bearer header" do
      assert Control.extract_bearer("Bearer abc123") == "abc123"
      assert Control.extract_bearer("bearer abc123") == "abc123"
      assert Control.extract_bearer("  Bearer   abc123  ") == "abc123"
    end

    test "returns nil for missing or malformed headers" do
      assert Control.extract_bearer(nil) == nil
      assert Control.extract_bearer("Basic abc") == nil
      assert Control.extract_bearer("") == nil
    end
  end
end
