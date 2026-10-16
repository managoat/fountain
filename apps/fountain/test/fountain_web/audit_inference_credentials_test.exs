defmodule FountainWeb.AuditInferenceCredentialsTest do
  @moduledoc """
  BYO inference credentials are audited from every surface (#546).

  These are secret material on par with environment and vault secrets, which
  have audited since #530. Two of the three surfaces that write them already
  recorded their own event — the settings LiveView and the API controller —
  and the onboarding wizard, saving the same credential through the same
  context function, recorded nothing. That is the shape this campaign keeps
  finding: a per-caller obligation one caller does not know about.

  The recording now lives in `put_credential/5`, so these tests split into the
  event itself and each surface's attribution.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.{Audit, Crypto, InferenceCredentials}

  @token "sk-ant-audit-canary-must-not-leak"

  defp events_for(user_id), do: Audit.list_recent_for_user(user_id, 100)

  defp find_action(user_id, action) do
    Enum.find(events_for(user_id), &(&1.action == action))
  end

  defp dek!(user_id) do
    {:ok, dek} = Crypto.load_tenant_key(user_id)
    dek
  end

  describe "the context records the write" do
    test "setting a credential" do
      user = insert_verified_user()

      {:ok, _} =
        InferenceCredentials.put_credential(user.id, dek!(user.id), :anthropic_api_key, @token)

      event = find_action(user.id, "inference_credential.write")
      assert event.resource_type == "inference_credential"
      assert event.resource_id == "anthropic_api_key"
      assert event.metadata["provider"] == "anthropic_api_key"
      assert event.actor == "self"
    end

    test "clearing a credential is a distinct action" do
      user = insert_verified_user()
      dek = dek!(user.id)

      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, @token)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, nil)

      assert find_action(user.id, "inference_credential.delete").resource_id ==
               "anthropic_api_key"
    end

    test "an empty string clears rather than writes" do
      # `put_credential/5` treats "" as a clear, so the event has to agree —
      # otherwise the trail claims a credential was set when it was removed.
      user = insert_verified_user()

      {:ok, _} = InferenceCredentials.put_credential(user.id, dek!(user.id), :openai_api_key, "")

      assert find_action(user.id, "inference_credential.delete")
      refute find_action(user.id, "inference_credential.write")
    end

    test "the credential itself never reaches the trail" do
      user = insert_verified_user()

      {:ok, _} =
        InferenceCredentials.put_credential(user.id, dek!(user.id), :anthropic_api_key, @token)

      events = events_for(user.id)

      # Guard the guard (#406): an empty list would pass the refute vacuously.
      assert Enum.any?(events, &(&1.action == "inference_credential.write"))

      for event <- events do
        refute inspect(event) =~ @token
      end
    end
  end

  describe "the API surface attributes its write" do
    test "PUT /api/inference-credentials/:provider", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      # validate: false skips the provider ping, so this stays in the async
      # module — the network stub is what forces the UI tests into their own.
      conn
      |> authed_with_key(raw_key)
      |> put_json("/api/account/inference-credentials/anthropic_api_key", %{
        "value" => @token,
        "validate" => false
      })
      |> json_response(200)

      event = find_action(user.id, "inference_credential.write")
      assert event.actor == "api"
      assert event.resource_id == "anthropic_api_key"
    end

    test "DELETE clears and records", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      {:ok, _} =
        InferenceCredentials.put_credential(user.id, dek!(user.id), :anthropic_api_key, @token)

      conn
      |> authed_with_key(raw_key)
      |> delete("/api/account/inference-credentials/anthropic_api_key")
      |> response(204)

      assert find_action(user.id, "inference_credential.delete").actor == "api"
    end
  end
end

# The validator makes a real HTTP call, stubbed with Mimic — the stub has to be
# visible to the LiveView process, which needs global mode and therefore its own
# non-async module.
defmodule FountainWeb.AuditInferenceCredentialsUiTest do
  @moduledoc false

  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Audit

  @token "sk-ant-ui-canary"

  setup :set_mimic_global

  setup do
    stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)
    :ok
  end

  defp events_for(user_id), do: Audit.list_recent_for_user(user_id, 100)

  defp find_action(user_id, action) do
    Enum.find(events_for(user_id), &(&1.action == action))
  end

  # A first save, by an account that has set nothing up, is audited (#546).
  test "saving from the settings page is attributed to the browser", %{conn: conn} do
    user = insert_verified_user()

    {:ok, lv, _html} = live(login_user(conn, user), ~p"/account?open=inference-credentials")

    render_click(with_target(lv, "#inference-credentials-panel"), "save", %{
      "provider" => "anthropic_api_key",
      "value" => @token
    })

    event = find_action(user.id, "inference_credential.write")
    assert event, "saving from settings must be audited (#546)"
    assert event.actor == "ui"
    assert event.request_ip
  end

  test "one write through the UI records one event, not two", %{conn: conn} do
    # The LiveView used to record its own event; that call had to go when the
    # context took the job over, or every save would land twice.
    user = insert_verified_user()

    {:ok, lv, _html} = live(login_user(conn, user), ~p"/account?open=inference-credentials")

    render_click(with_target(lv, "#inference-credentials-panel"), "save", %{
      "provider" => "anthropic_api_key",
      "value" => @token
    })

    assert Enum.count(events_for(user.id), &(&1.action == "inference_credential.write")) == 1
  end

  test "clearing from the settings page is attributed too", %{conn: conn} do
    user = insert_verified_user()

    {:ok, lv, _html} = live(login_user(conn, user), ~p"/account?open=inference-credentials")

    render_click(with_target(lv, "#inference-credentials-panel"), "save", %{
      "provider" => "anthropic_api_key",
      "value" => @token
    })

    render_click(with_target(lv, "#inference-credentials-panel"), "clear", %{
      "provider" => "anthropic_api_key"
    })

    assert find_action(user.id, "inference_credential.delete").actor == "ui"
  end
end
