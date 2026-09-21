defmodule Fountain.Broker.Native.ProtectedCompiler do
  @moduledoc """
  The fixed Codex policy of a managed ChatGPT grant, compiled apart from
  ordinary secrets (ADR 0052 decision 6).

  Two halves, and neither ever holds a bearer:

    * `policy/1` -- the `Managoat.Broker.ProtectedRule` for one ChatGPT
      account: the Codex backend's host and port, the one route and method
      the pinned client uses, the account id the proxy sends as
      `chatgpt-account-id`, the request headers that survive, and that a
      query string on the route is refused. Nothing a tenant configures
      reaches it.
    * `compile/3` -- the ordinary rules of a session that also carries a
      managed grant, from the same `brokered` map and bindings every other
      session is built from. Reserved names and placeholders in those inputs
      fail compilation, including bindings persisted before
      `Fountain.ChatGPTAccounts.Reserved` refused them at the write, and so
      does any rule that would inject into the protected route (an exact
      host, a wildcard, a path pattern). Errors carry no supplied value.
      Ordinary tenant templates keep their ordinary inputs.

  The grant is not an input to either. `Fountain.Broker.Native.Sessions`
  stores which grant a session may use as authorization data, and resolves
  the bearer for one request at a time
  (`Fountain.ChatGPTAccounts.protected_credential/2`); the library injects it
  and the identity header itself, on the policy's destination only, refuses
  protocol upgrades on the whole session, and refuses a response on the
  protected route that repeats the bearer or arrives compressed
  (`managoat_broker` 0.15; what that does and does not recognise is in
  `Managoat.Broker.ProtectedRule`).

  Only the HTTP Responses surface is supported. See the adjacent
  compatibility fixture (`test/fixtures/codex_protected`) for the audited
  client and what is still unmeasured.
  """

  alias Fountain.Broker.Native
  alias Fountain.ChatGPTAccounts.Reserved
  alias Managoat.Broker.{ProtectedRule, Session}

  @path "/backend-api/codex/responses"

  # `accept-encoding` is not here: the library sends `identity` on every
  # protected request whatever the client asked for, because it searches the
  # response for the bearer and cannot search a compressed one. Naming it
  # would promise something that does not happen. `content-encoding` is the
  # request body's, which the pinned client compresses.
  @headers ~w(accept content-type content-encoding user-agent originator
              version session-id thread-id x-client-request-id x-openai-subagent
              x-codex-turn-state x-codex-turn-metadata x-codex-beta-features
              x-codex-window-id x-codex-routing-hint)

  @doc "The rule name the request log and `credential_keys` file a protected request under."
  @spec rule_name() :: String.t()
  def rule_name, do: "codex-chatgpt"

  @doc """
  The ordinary half of a managed session: `{:ok, %{rules:, http_only: true,
  unmatched_host_policy:}}`, or a fixed, value-free reason.
  """
  @spec compile(map(), map(), Fountain.Broker.network()) ::
          {:ok,
           %{rules: [Managoat.Broker.Rule.t()], http_only: true, unmatched_host_policy: atom()}}
          | {:error,
             :managed_credential_conflict
             | :managed_destination_conflict
             | :invalid_broker_configuration}
  def compile(brokered, bindings, network) when is_map(brokered) and is_map(bindings) do
    cond do
      # Everything that names a credential or says where one goes is held to
      # the strict rule; a secret's value to the one for values, so a script
      # that mentions the reserved name does not fail every provision
      # (`Fountain.ChatGPTAccounts.Reserved`, "Names and values").
      Reserved.conflict?([Map.keys(brokered), bindings, network]) or
          Enum.any?(Map.values(brokered), &Reserved.value_conflict?/1) ->
        {:error, :managed_credential_conflict}

      not ordinary_secrets?(brokered) ->
        {:error, :invalid_broker_configuration}

      true ->
        rules = Native.rules_for(brokered, bindings, network)

        # Prove the effective rules do not conflict, including wildcards and
        # path patterns in older rows. The library repeats this at admission.
        # The identity is not an input to that question.
        case ProtectedRule.prepare(template(), %Session{rules: rules}, request(), []) do
          {:ok, _headers} ->
            {:ok,
             %{
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

  def compile(_brokered, _bindings, _network), do: {:error, :invalid_broker_configuration}

  @doc """
  The protected policy for one ChatGPT account id, or `{:error,
  :invalid_managed_identity}` for an id the library would not send as a
  header value.
  """
  @spec policy(term()) :: {:ok, ProtectedRule.t()} | {:error, :invalid_managed_identity}
  def policy(identity) when is_binary(identity) do
    policy = %{template() | identity: identity}

    valid? =
      not Reserved.conflict?(identity) and
        ProtectedRule.valid_session?(%Session{
          protected: policy,
          http_only: true,
          authorization: :validation_only
        })

    if valid?, do: {:ok, policy}, else: {:error, :invalid_managed_identity}
  end

  def policy(_identity), do: {:error, :invalid_managed_identity}

  defp template do
    {host, port} = backend()

    %ProtectedRule{
      name: rule_name(),
      host: host,
      port: port,
      paths: [@path],
      methods: ["POST"],
      identity: "unset",
      identity_header: "chatgpt-account-id",
      allowed_headers: @headers,
      # The library's default, written down so a later default cannot widen
      # the route: the pinned client sends no query, and one the sandbox
      # wrote would go out under the bearer.
      query: :refuse
    }
  end

  defp request do
    {host, port} = backend()
    %{scheme: :https, host: host, port: port, target: @path, method: "POST"}
  end

  # `chatgpt.com:443`, always, in every environment but the test suite's: the
  # proxy rig's origin listens on loopback, and the only way to drive the real
  # listener through the protected path is to point the policy at it. Read
  # from application config and from nowhere a tenant or an operator's
  # environment reaches; `config/runtime.exs` does not set it.
  defp backend, do: Application.get_env(:fountain, :codex_chatgpt_backend, {"chatgpt.com", 443})

  defp ordinary_secrets?(brokered),
    do: Enum.all?(brokered, fn {key, value} -> is_binary(key) and is_binary(value) end)

  defp unmatched_host_policy(:unrestricted), do: :passthrough
  defp unmatched_host_policy({:limited, _hosts}), do: :deny
end
