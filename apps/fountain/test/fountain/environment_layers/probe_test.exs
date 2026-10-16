defmodule Fountain.EnvironmentLayers.ProbeTest do
  use ExUnit.Case, async: true
  alias Fountain.EnvironmentLayers.Probe

  test "resolves HEAD, branch precedence and annotated tag peeling" do
    a = String.duplicate("a", 40)
    b = String.duplicate("b", 40)
    assert {:ok, ^a} = Probe.parse_revision(a <> "\tHEAD\n", "HEAD")

    assert {:ok, ^a} =
             Probe.parse_revision(b <> "\trefs/tags/main\n" <> a <> "\trefs/heads/main\n", "main")

    assert {:ok, ^b} =
             Probe.parse_revision(a <> "\trefs/tags/v1\n" <> b <> "\trefs/tags/v1^{}\n", "v1")

    assert {:error, :revision_unavailable} = Probe.parse_revision("not-a-sha\tHEAD\n", "HEAD")

    assert {:error, :revision_unavailable} =
             Probe.parse_revision(a <> "\trefs/heads/other\n", "main")
  end
end
