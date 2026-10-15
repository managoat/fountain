defmodule Fountain.InstructionModelsTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  # The skills an agent is handed: the one every sandbox mounts, and the
  # external one published with the manual at /skill (site/priv/llms/, since
  # the manual left the server; decisions/0081).
  test "shipped skills never recommend adapter-refused models" do
    skills =
      Path.wildcard(Path.join(@repo_root, "apps/fountain/priv/sprite_skills/**/SKILL.md")) ++
        Path.wildcard(Path.join(@repo_root, "site/priv/llms/SKILL.md"))

    assert length(skills) >= 2

    refused =
      for path <- skills,
          content = File.read!(path),
          {model, observed} <- Fountain.RefusedModels.all(),
          String.contains?(content, model) do
        {Path.relative_to(path, @repo_root), model, observed}
      end

    assert refused == [], "Shipped instructions name refused models: #{inspect(refused)}"
  end
end
