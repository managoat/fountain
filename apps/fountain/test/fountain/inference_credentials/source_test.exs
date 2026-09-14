defmodule Fountain.InferenceCredentials.SourceTest do
  @moduledoc """
  The stored shape of a source (`dump/1` and `load/1`) against literal maps in
  the shape rows written on 2026-09-13 hold, in `conversations.inference_source`,
  `turns.inference_source` and `sandboxes.codex_inference_source`.

  Nothing else loads a historical map: every other test dumps what it just
  resolved. Renaming a `kind` or `scope` atom, or dropping a key, would make
  `load/1` decode `nil` on every stored row and every wake refuse with
  `:inference_source_changed`, and this is the test that would say so.
  """
  use ExUnit.Case, async: true

  alias Fountain.InferenceCredentials.Source

  # Every key a stored map has, string-keyed, string-valued where the code
  # writes an atom. `"origin"` is in the map because every row carries it;
  # since it became derived, `load/1` ignores it and `dump/1` writes it back.
  @platform %{
    "origin" => "platform",
    "scope" => "platform",
    "kind" => "codex_chatgpt_access_token",
    "identity" => "platform:chatgpt:0d1c8a2e-4f6b-4c9a-9e1d-2b3c4d5e6f70",
    "revision" => "7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d",
    "set_id" => nil,
    "runtime" => "codex",
    "model" => "openai/gpt-5.5-codex",
    "environment_id" => nil,
    "vault_id" => nil
  }

  @own %{
    "origin" => "own",
    "scope" => "credential",
    "kind" => "anthropic_api_key",
    "identity" => "credential:3f2a1b0c-9d8e-4f7a-b6c5-d4e3f2a1b0c9:anthropic_api_key",
    "revision" => "c1d2e3f4-a5b6-4c7d-8e9f-a0b1c2d3e4f5",
    "set_id" => "3f2a1b0c-9d8e-4f7a-b6c5-d4e3f2a1b0c9",
    "runtime" => "claude",
    "model" => "anthropic/claude-opus-5",
    "environment_id" => "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d",
    "vault_id" => nil
  }

  @tenant_secret %{
    "origin" => "own",
    "scope" => "tenant_secret",
    "kind" => "gemini_api_key",
    "identity" =>
      "vault:9b8a7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d:2c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f",
    "revision" => "e5f6a7b8-c9d0-4e1f-8a2b-3c4d5e6f7a8b",
    "set_id" => "3f2a1b0c-9d8e-4f7a-b6c5-d4e3f2a1b0c9",
    "runtime" => "opencode",
    "model" => "google/gemini-2.5-pro",
    "environment_id" => nil,
    "vault_id" => "9b8a7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d"
  }

  @missing %{
    "origin" => "own",
    "scope" => "missing",
    "kind" => nil,
    "identity" => "missing",
    "revision" => "1",
    "set_id" => nil,
    "runtime" => "claude",
    "model" => "anthropic/claude-opus-5",
    "environment_id" => nil,
    "vault_id" => nil
  }

  test "a platform row loads, is the platform's, and dumps back equal" do
    assert %Source{
             scope: :platform,
             kind: :codex_chatgpt_access_token,
             identity: "platform:chatgpt:" <> _,
             set_id: nil,
             runtime: "codex",
             model: "openai/gpt-5.5-codex"
           } = source = Source.load(@platform)

    assert Source.platform?(source)
    assert Source.origin(source) == "platform"
    assert Source.dump(source) == @platform
  end

  test "an own row loads, is not the platform's, and dumps back equal" do
    assert %Source{
             scope: :credential,
             kind: :anthropic_api_key,
             set_id: "3f2a1b0c-9d8e-4f7a-b6c5-d4e3f2a1b0c9",
             environment_id: "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d",
             vault_id: nil
           } = source = Source.load(@own)

    refute Source.platform?(source)
    assert Source.origin(source) == "own"
    assert Source.dump(source) == @own
  end

  test "the other own scopes round-trip too" do
    for map <- [@tenant_secret, @missing] do
      source = Source.load(map)
      refute Source.platform?(source)
      assert Source.dump(source) == map
    end

    assert %Source{scope: :tenant_secret, kind: :gemini_api_key} = Source.load(@tenant_secret)
    assert %Source{scope: :missing, kind: nil, revision: "1"} = Source.load(@missing)
  end

  test "the stored origin is derived, not read: a map that disagrees with its scope dumps corrected" do
    assert Source.dump(Source.load(%{@platform | "origin" => "own"})) == @platform
    assert Source.dump(Source.load(%{@own | "origin" => "platform"})) == @own
  end

  test "every constructor dumps the origin its scope implies" do
    assert Source.dump(Source.platform())["origin"] == "platform"

    for source <- [Source.credential(), Source.tenant_secret(), Source.none(), Source.missing()] do
      assert Source.dump(source)["origin"] == "own"
    end
  end

  test "nil round-trips as nil" do
    assert Source.dump(nil) == nil
    assert Source.load(nil) == nil
  end
end
