defmodule SymphonyElixir.RedactionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Redaction

  describe "redact/1 positive cases" do
    test "redacts GH OAuth tokens" do
      input = "got token gho_AAAABBBBCCCCDDDDEEEEFFFFGGGG and stuff"
      assert Redaction.redact(input) =~ "[REDACTED]"
      refute Redaction.redact(input) =~ "AAAABBBBCCCC"
    end

    test "redacts fine-grained PATs" do
      input = "github_pat_11ABCDEFG_abc123def456ghi789jkl_more"
      result = Redaction.redact(input)
      assert result =~ "[REDACTED]"
      refute result =~ "github_pat_11ABCDEFG_abc123def456ghi789jkl"
    end

    test "redacts Authorization: Bearer headers but keeps the prefix for log context" do
      input = "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789"
      result = Redaction.redact(input)
      assert result =~ "[REDACTED]"
      assert result =~ "Authorization:"
      assert result =~ "Bearer "
      refute result =~ "abcdefghijklmnopqrstuvwxyz"
    end

    test "redacts plain `Bearer <token>` even without the Authorization label" do
      input = "header X-Auth: Bearer abcdefghijklmnopqrstuvwxyz123456"
      result = Redaction.redact(input)
      refute result =~ "abcdefghijklmnopqrstuvwxyz"
    end

    test "redacts URLs with embedded credentials" do
      input = "https://user:supersecret@github.com/org/repo.git"
      result = Redaction.redact(input)
      refute result =~ "supersecret"
    end

    test "redacts GH_TOKEN= and GITHUB_TOKEN= environment-style assignments" do
      input = "env GH_TOKEN=ghs_secrettokenvalueABCDEFGHIJ; GITHUB_TOKEN=plainvalue"
      result = Redaction.redact(input)
      assert result =~ "GH_TOKEN=[REDACTED]"
      assert result =~ "GITHUB_TOKEN=[REDACTED]"
    end
  end

  describe "redact/1 negative cases" do
    test "does not redact ordinary words that look token-shaped" do
      input = "This is a plain English sentence about gh and tokens but no values."
      assert Redaction.redact(input) == input
    end

    test "does not redact short identifiers" do
      input = "ghp_short and gho_xyz are not real tokens"
      assert Redaction.redact(input) == input
    end

    test "passes through non-binary input" do
      assert Redaction.redact(:atom) == :atom
      assert Redaction.redact(123) == 123
      assert Redaction.redact(nil) == nil
    end
  end

  describe "contains_secret?/1" do
    test "returns true for known token shapes" do
      assert Redaction.contains_secret?("ghp_aaaaaaaaaaaaaaaaaaaaaaaaaa")
      assert Redaction.contains_secret?("Authorization: Bearer aaaabbbbccccdddd")
      assert Redaction.contains_secret?("GH_TOKEN=value")
    end

    test "returns false for ordinary text" do
      refute Redaction.contains_secret?("hello world")
    end
  end
end
