defmodule Fountain.FirstRequestTest do
  @moduledoc """
  The first request has one source. These tests are what stops
  `GET /api/catalog` and `docs/quickstart.md` from drifting apart, which is
  the failure the shared file exists to prevent.
  """
  use ExUnit.Case, async: true

  alias Fountain.FirstRequest

  @repo_root Path.expand("../../../..", __DIR__)

  describe "the templates" do
    test "are the files the manual includes, verbatim" do
      for {render, path} <- [
            {FirstRequest.curl_template(), "docs/snippets/first-request.sh"},
            {FirstRequest.typescript_template(), "docs/snippets/first-request.ts"}
          ] do
        on_disk = @repo_root |> Path.join(path) |> File.read!() |> String.trim_trailing()
        assert render == on_disk, "#{path} is not what Fountain.FirstRequest serves"
      end
    end

    test "both send the same prompt" do
      assert FirstRequest.curl_template() =~ FirstRequest.prompt()
      assert FirstRequest.typescript_template() =~ FirstRequest.prompt()
    end

    test "the curl posts a conversation and the TypeScript runs the SDK" do
      assert FirstRequest.curl_template() =~ "/api/conversations"
      assert FirstRequest.curl_template() =~ "Authorization: Bearer"
      assert FirstRequest.typescript_template() =~ "@managoat/fountain-sdk"
      assert FirstRequest.typescript_template() =~ "fountain.runRequest("
    end

    test "carry every placeholder between them, so the manual reads as instructions" do
      both = FirstRequest.curl_template() <> FirstRequest.typescript_template()

      for token <- FirstRequest.placeholders() do
        assert String.contains?(both, token), "#{token} is in placeholders/0 but in no snippet"
      end
    end
  end

  describe "curl/1" do
    test "substitutes the key, the agent and the instance" do
      rendered =
        FirstRequest.curl(
          base_url: "https://fountain.example",
          api_key: "ftn_abc123",
          agent_id: "agent-uuid"
        )

      assert rendered =~ "https://fountain.example/api/conversations"
      assert rendered =~ "Bearer ftn_abc123"
      assert rendered =~ ~s(\\"agent-uuid\\")
    end

    test "leaves what it was not given alone" do
      rendered = FirstRequest.curl(base_url: "https://fountain.example")

      assert rendered =~ "$FOUNTAIN_API_KEY"
      assert rendered =~ "$FOUNTAIN_AGENT_ID"
      refute rendered =~ "$FOUNTAIN_BASE_URL"
    end
  end

  describe "typescript/1" do
    test "uses the agent ID and fills the constructor a copied snippet needs" do
      rendered =
        FirstRequest.typescript(
          base_url: "https://fountain.example",
          api_key: "ftn_abc123",
          agent_id: "agent-uuid"
        )

      assert rendered =~ ~S|agent_id: "agent-uuid"|

      assert rendered =~
               ~S|new Fountain({ apiKey: "ftn_abc123", baseUrl: "https://fountain.example" })|

      refute rendered =~ "new Fountain()"
      refute rendered =~ "$FOUNTAIN_AGENT_ID"
    end

    test "keeps the bare constructor when there is nothing to put in it" do
      assert FirstRequest.typescript(agent_id: "agent-uuid") =~ "new Fountain()"
    end
  end

  # The #884 failure: a compile-time read of a file the Docker build stage does
  # not COPY kills `mix release`, no image is built, CI stays green and the
  # deploy silently never happens. The snippets live under docs/ so that the
  # existing line covers them; this is what says so out loud.
  test "the Docker build stage copies what this module reads at compile time" do
    dockerfile = @repo_root |> Path.join("Dockerfile") |> File.read!()

    assert dockerfile =~ ~r/^COPY docs \.\/docs$/m,
           "Fountain.FirstRequest reads docs/snippets/ at compile time"
  end

  test "a fully substituted render carries no placeholder into anyone's terminal" do
    rendered =
      FirstRequest.curl(base_url: "https://x.test", api_key: "ftn_k", agent_id: "a") <>
        FirstRequest.typescript(
          base_url: "https://x.test",
          api_key: "ftn_k",
          agent_id: "agent-uuid"
        )

    for token <- FirstRequest.placeholders() do
      refute String.contains?(rendered, token), "#{token} survived substitution"
    end
  end
end
