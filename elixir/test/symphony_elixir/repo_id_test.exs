defmodule SymphonyElixir.RepoIdTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RepoId

  describe "valid?/1" do
    test "accepts well-formed owner/repo identifiers" do
      assert RepoId.valid?("openai/symphony")
      assert RepoId.valid?("OWNER/repo")
      assert RepoId.valid?("a-b/c.d_e")
      assert RepoId.valid?("user_1/some-repo.name")
    end

    test "rejects malformed identifiers" do
      refute RepoId.valid?("")
      refute RepoId.valid?("just-owner")
      refute RepoId.valid?("/repo")
      refute RepoId.valid?("owner/")
      refute RepoId.valid?("owner/repo/extra")
      refute RepoId.valid?("owner repo")
      refute RepoId.valid?("owner/re po")
      refute RepoId.valid?("owner/$repo")
      refute RepoId.valid?("owner;rm/repo")
      refute RepoId.valid?(nil)
      refute RepoId.valid?(123)
    end
  end

  describe "split/1" do
    test "splits a valid identifier" do
      assert {:ok, {"openai", "symphony"}} = RepoId.split("openai/symphony")
    end

    test "rejects an invalid identifier" do
      assert {:error, :invalid_repo} = RepoId.split("not-valid")
    end
  end
end
