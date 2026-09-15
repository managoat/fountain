defmodule FountainWeb.ApiSpec.FixtureRuntimeTest do
  @moduledoc """
  `fountain-fixture` is out of the published contract and still admitted by a
  deployment that enables it (#1716).

  The fixture is one account's test harness on one deployment, so it has no
  business in the exported contract or in the SDK types projected out of it.
  It is also created through `POST /api/agents` like any other agent, and
  `CastAndValidate` casts `runtime` against the served spec — so unshipping it
  from the enum without widening the served spec would refuse the deployed
  deterministic suite at the cast, before its changeset ever ran. Both halves
  are pinned here; either one alone is a regression.
  """

  # Enabling the fixture changes application-wide admission, and the spec
  # cache is global.
  use FountainWeb.ConnCase, async: false

  alias Fountain.Agents.Agent
  alias FountainWeb.ApiSpec

  @fixture "fountain-fixture"

  setup do
    previous = Application.get_env(:fountain, :deployed_acp_fixture)
    Application.delete_env(:fountain, :deployed_acp_fixture)
    refresh_spec()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :deployed_acp_fixture, previous),
        else: Application.delete_env(:fountain, :deployed_acp_fixture)

      refresh_spec()
    end)

    :ok
  end

  defp refresh_spec, do: OpenApiSpex.Plug.Cache.adapter().erase(ApiSpec)

  defp enable(user_id), do: configure(%{enabled: true, user_id: user_id})

  defp configure(config) do
    Application.put_env(:fountain, :deployed_acp_fixture, config)
    refresh_spec()
  end

  # Every resolved component schema's `runtime` enum, by schema title.
  defp runtime_enums do
    ApiSpec.spec().components.schemas
    |> Enum.flat_map(fn {name, schema} ->
      case schema.properties[:runtime] do
        %OpenApiSpex.Schema{enum: enum} when is_list(enum) -> [{name, enum}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  test "the exported contract names the packaged runtimes and not the fixture" do
    enums = runtime_enums()

    assert map_size(enums) > 0, "no component schema declares a runtime enum any more"

    for {name, enum} <- enums do
      assert Enum.sort(enum) == Enum.sort(Agent.packaged_runtimes()),
             "#{name}.runtime should be the packaged runtimes, got #{inspect(enum)}"
    end

    refute ApiSpec.spec() |> Jason.encode!() |> String.contains?(@fixture)
  end

  test "a deployment with the fixture enabled names it in its own spec" do
    enable(Ecto.UUID.generate())

    for {name, enum} <- runtime_enums() do
      assert @fixture in enum, "#{name}.runtime should name the fixture on this deployment"

      assert Enum.sort(enum) == Enum.sort(Agent.known_runtimes()),
             "#{name}.runtime widened to something other than the known runtimes"
    end
  end

  # An agent the fixture created outlives the flag on purpose (#2128), and the
  # schema guard validates what this deployment renders for it.
  test "turning the flag off keeps the fixture in the enum while the account is named" do
    configure(%{enabled: false, user_id: Ecto.UUID.generate()})

    refute Fountain.DeployedACPFixture.enabled?()

    for {name, enum} <- runtime_enums() do
      assert @fixture in enum, "#{name}.runtime drops the fixture the deployment can still serve"
    end
  end

  test "a deployment that names no fixture account keeps it out, however configured" do
    for config <- [%{enabled: true, user_id: nil}, %{enabled: true, user_id: "not-a-uuid"}] do
      configure(config)

      for {name, enum} <- runtime_enums() do
        refute @fixture in enum, "#{name}.runtime names the fixture for #{inspect(config)}"
      end
    end
  end

  defp create(conn, raw_key) do
    conn
    |> authed_with_key(raw_key)
    |> post_json("/api/agents", %{
      name: "fixture",
      runtime: @fixture,
      model: "fixture/deterministic-v1"
    })
  end

  describe "POST /api/agents" do
    setup do
      user = insert_verified_user()
      {_key, raw_key} = insert_api_key(user)
      %{user: user, raw_key: raw_key}
    end

    test "the enabled account reaches the changeset, not a spec refusal", ctx do
      enable(ctx.user.id)

      assert %{"data" => %{"runtime" => @fixture}} =
               json_response(create(ctx.conn, ctx.raw_key), 201)
    end

    test "another account is refused by the changeset, which is a 422", ctx do
      enable(Ecto.UUID.generate())

      assert %{"errors" => errors} = json_response(create(ctx.conn, ctx.raw_key), 422)
      assert errors["runtime"] == ["fixture is not enabled for this account"]
    end

    test "a deployment without the fixture refuses it at the spec", ctx do
      assert %{"errors" => errors} = json_response(create(ctx.conn, ctx.raw_key), 422)
      assert errors["runtime"] == ["Invalid value for enum"]
    end
  end
end
