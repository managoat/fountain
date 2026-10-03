defmodule Fountain.ReleasePinTest do
  # The self-host quick start pins a release image in six places. Those pins
  # sat at v0.3.0 through two releases, handing newcomers an image from before
  # the in-app first-login flow (#478), where EMAIL_DELIVERY=none dead-ends
  # signup. release-bump.yml bumps the pins in the release PR, and this test
  # runs on that PR, so a pin the workflow missed fails the bump itself
  # rather than surfacing two releases later. ci.yml's compose boot check
  # also reads the pin against mix.exs to know a bump tree from a broken one.
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  @pins [
    {"docker-compose.yml", ~r/fountain:\$\{FOUNTAIN_IMAGE_TAG:-(v[\d.]+)\}/},
    {".env.compose.example", ~r/^FOUNTAIN_IMAGE_TAG=(v[\d.]+)$/m},
    {"fly.toml", ~r/image = "ghcr\.io\/managoat\/fountain:(v[\d.]+)"/},
    {"deploy/k8s/kustomization.yaml", ~r/newTag: (v[\d.]+)/},
    {"deploy/k8s/deployment.yaml", ~r/image: ghcr\.io\/managoat\/fountain:(v[\d.]+)/}
  ]

  test "self-host image pins match the released version" do
    expected = "v" <> to_string(Application.spec(:fountain, :vsn))

    for {file, regex} <- @pins do
      pinned =
        case Regex.run(regex, File.read!(Path.join(@root, file))) do
          [_, tag] -> tag
          nil -> flunk("#{file}: image pin not found (pattern #{inspect(regex)})")
        end

      assert pinned == expected,
             "#{file} pins #{pinned} but the released version is #{expected}; " <>
               "release-bump.yml should have bumped it in the release commit"
    end
  end
end
