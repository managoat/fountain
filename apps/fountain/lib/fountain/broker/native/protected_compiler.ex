defmodule Fountain.Broker.Native.ProtectedCompiler do
  @moduledoc """
  Compiles the fixed Codex policy separately from ordinary secrets (ADR 0052).

  The typed grant is never passed to Native.rules_for/3. Reserved names,
  placeholders and copies of its bearer in ordinary inputs fail compilation,
  including persisted bindings that predate write validation. Errors contain
  no supplied values. Ordinary tenant templates retain their ordinary inputs.

  This is a preparation seam, not session issuance or authorization. Its output
  deliberately has no authorization reference and cannot form a valid protected
  broker session by itself. Adoption requires durable owner/generation checks at
  issuance, update and each request, plus draining legacy sockets on every node.
  Do not persist the input Grant or use its bearer as a cached session rule.

  Only the HTTP Responses surface is supported. See the adjacent compatibility
  fixture for the audited client and remaining rollout gates. Tenant bindings
  and network configuration cannot widen the protected destination or headers.
  """

  alias Fountain.Broker.Native
  alias Fountain.ChatGPTAccounts.{Grant, Reserved}
  alias Managoat.Broker.{ProtectedRule, Session}

  @path "/backend-api/codex/responses"
  @headers ~w(accept accept-encoding content-type content-encoding user-agent originator
              version session-id thread-id x-client-request-id x-openai-subagent
              x-codex-turn-state x-codex-turn-metadata x-codex-beta-features
              x-codex-window-id x-codex-routing-hint)

  @doc "Compile without putting managed credentials in ordinary rules or output."
  def compile(
        %Grant{access_token: token, source: %{account_id: identity}},
        brokered,
        bindings,
        network
      )
      when is_binary(token) and token != "" and is_map(brokered) and is_map(bindings) do
    policy = policy(identity)

    cond do
      not ProtectedRule.valid_session?(%Session{
        protected: policy,
        http_only: true,
        authorization: :validation_only
      }) ->
        {:error, :invalid_managed_identity}

      conflicting_inputs?([brokered, bindings, network, identity], token) ->
        {:error, :managed_credential_conflict}

      not ordinary_secrets?(brokered) ->
        {:error, :invalid_broker_configuration}

      true ->
        rules = Native.rules_for(brokered, bindings, network)

        # Prove the effective rules do not conflict, including wildcards and
        # path patterns in older rows. The library repeats this at admission.
        case ProtectedRule.prepare(policy, %Session{rules: rules}, request(), []) do
          {:ok, _headers} ->
            {:ok,
             %{
               protected: policy,
               rules: rules,
               http_only: true,
               unmatched_host_policy: unmatched_host_policy(network)
             }}

          {:error, :protected_conflict} ->
            {:error, :managed_destination_conflict}
        end
    end
  rescue
    # Persisted malformed ordinary input must not crash a caller into fallback
    # or include a credential in a MatchError/FunctionClauseError diagnostic.
    _ -> {:error, :invalid_broker_configuration}
  end

  def compile(_grant, _brokered, _bindings, _network), do: {:error, :invalid_managed_grant}

  defp policy(identity) do
    %ProtectedRule{
      name: "codex-chatgpt",
      host: "chatgpt.com",
      port: 443,
      paths: [@path],
      methods: ["POST"],
      identity: identity,
      identity_header: "chatgpt-account-id",
      allowed_headers: @headers
    }
  end

  defp request do
    %{scheme: :https, host: "chatgpt.com", port: 443, target: @path, method: "POST"}
  end

  defp conflicting_inputs?(inputs, token),
    do: Reserved.conflict?(inputs) or contains_bearer?(inputs, token)

  defp ordinary_secrets?(brokered),
    do: Enum.all?(brokered, fn {key, value} -> is_binary(key) and is_binary(value) end)

  defp unmatched_host_policy(:unrestricted), do: :passthrough
  defp unmatched_host_policy({:limited, _hosts}), do: :deny

  defp contains_bearer?(%_{} = value, token),
    do: value |> Map.from_struct() |> contains_bearer?(token)

  defp contains_bearer?(value, token) when is_map(value),
    do:
      Enum.any?(value, fn {key, value} ->
        contains_bearer?(key, token) or contains_bearer?(value, token)
      end)

  defp contains_bearer?(value, token) when is_list(value),
    do: Enum.any?(value, &contains_bearer?(&1, token))

  defp contains_bearer?(value, token) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_bearer?(token)

  defp contains_bearer?(value, token) when is_binary(value), do: String.contains?(value, token)
  defp contains_bearer?(_value, _token), do: false
end
