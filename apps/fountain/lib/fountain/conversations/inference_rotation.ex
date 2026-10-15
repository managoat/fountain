defmodule Fountain.Conversations.InferenceRotation do
  @moduledoc """
  A bound inference credential rotated in place reaches the conversation
  (#2602, ADR 0053's 2026-10-15 amendment).

  The turn gate accepts a source whose revision moved while its identity
  stayed (`Fountain.InferenceCredentials.Source.rotation?/2`). This module
  is what makes the next turn run on the new value rather than the one the
  server read at provision:

    * **Brokered.** The value lives in the broker's rules, under the
      credential's env var name; the sandbox holds a placeholder.
      `reread_brokered/1` puts the new value in `brokered`, and
      `Fountain.Conversations.Egress`'s refresh rewrites the rules in place
      (#2548), so the idle peer keeps its connection and its next request
      carries the new key. A secret write's live refresh runs it too, so an
      environment or vault secret rotated mid-turn reaches that turn.
    * **Unbrokered.** The value is in the spawn env of the adapter process,
      and only a new process reads it. `refresh_unbrokered/1` swaps it in
      `sprite_env` and says so, and the caller closes the idle peer: the
      next turn spawns a new adapter on the new env and resumes the session.
      A turn already running finishes on the value it started with. No file
      in the sandbox holds it (`Fountain.Conversations.Identity.disk_env/1`
      keeps inference inputs out of `~/.env`), except on codex.

  Codex reads its API key from `~/.codex/auth.json`, which
  `Managoat.Runtimes.Codex.prepare_sandbox/3` writes from `sprite_env` at
  provision and on every reattach. Brokered, that file holds the key's
  placeholder (`Fountain.Broker.placeholder/1`, the same string for every
  value), so a rotation leaves it alone and the broker's rules carry the new
  key. Unbrokered, `refresh_unbrokered/1` rewrites the file with the new key
  before it moves anything else, and the closed peer covers whatever codex
  cached in memory. A write that fails refuses the turn: the state keeps the
  old value, so the next turn tries again rather than running on the old key.

  A ChatGPT subscription does not rotate (`Source.rotates?/1`): its token
  refresh has its own path (`Fountain.Conversations.Egress`), so neither
  function touches it.

  The server's `inference_source` keeps the revision it was bound with: turn
  admission compares it with the conversation's row, and the row's revision
  moves only when a wake or provision reserves the source again.
  """

  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Managoat.Runtimes.Codex

  @doc """
  The bound source's value now, as `{kind, old, new}`, when it differs from
  the one the server holds; nil when it does not, when the source does not
  rotate, or when it no longer resolves (the turn gate refuses that).
  """
  @spec rotated(map()) :: {atom(), String.t(), String.t()} | nil
  def rotated(state) do
    with %Source{kind: kind} = source <- Map.get(state, :inference_source),
         true <- Source.rotates?(source),
         {:ok, _fresh, creds} <-
           InferenceCredentials.resolve(state.user_id, source.model, source.runtime,
             environment_id: source.environment_id,
             vault_id: source.vault_id,
             expected_source: Source.dump(source)
           ),
         new when is_binary(new) and new != "" <- creds[kind],
         old when is_binary(old) and old != new <- state.inference_credentials[kind] do
      {kind, old, new}
    else
      _ -> nil
    end
  end

  @doc """
  For a brokered conversation: the new value in `inference_credentials` and
  in `brokered` under its env var name, and whether anything moved. The
  caller registers `brokered` for redaction and rewrites the rules.
  """
  @spec reread_brokered(map()) :: {map(), boolean()}
  def reread_brokered(state) do
    case rotated(state) do
      nil ->
        {state, false}

      {kind, _old, new} ->
        key = Map.fetch!(InferenceCredentials.env_names(), kind)

        brokered =
          if Map.has_key?(state.brokered, key),
            do: Map.put(state.brokered, key, new),
            else: state.brokered

        {%{
           state
           | inference_credentials: Map.put(state.inference_credentials, kind, new),
             brokered: brokered
         }, true}
    end
  end

  @doc """
  For an unbrokered conversation: the new value in `inference_credentials`,
  `env_credentials` and `sprite_env`, registered for redaction, and whether
  it moved, in which case the caller closes the idle peer so the next turn
  spawns on it. On codex the sandbox's `auth.json` is rewritten first, and
  `{:error, {:codex_auth_write, reason}}` when that fails, with nothing
  moved. A brokered state comes back unchanged.
  """
  @spec refresh_unbrokered(map()) :: {map(), boolean()} | {:error, term()}
  def refresh_unbrokered(%{broker: nil} = state) do
    with {kind, old, new} <- rotated(state),
         :ok <- write_auth_file(state, kind, new) do
      names = Map.fetch!(InferenceCredentials.env_aliases(), kind)

      sprite_env =
        Enum.map(state.sprite_env, fn
          {name, ^old} = pair -> if to_string(name) in names, do: {name, new}, else: pair
          pair -> pair
        end)

      Fountain.Conversations.Redaction.add(state.conversation_id, [{hd(names), new}])

      {%{
         state
         | inference_credentials: Map.put(state.inference_credentials, kind, new),
           env_credentials: Map.put(state.env_credentials, kind, new),
           sprite_env: sprite_env
       }, true}
    else
      nil -> {state, false}
      {:error, _} = error -> error
    end
  end

  def refresh_unbrokered(state), do: {state, false}

  # Codex reads its key from `auth.json`, not from its env: write the new one
  # in the shape and mode provisioning does.
  defp write_auth_file(
         %{inference_source: %Source{runtime: "codex"}} = state,
         :openai_api_key,
         key
       ) do
    case Managoat.Sandbox.write_file(state.handle, Codex.auth_path(), Codex.auth_json(key),
           mode: 0o600
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:codex_auth_write, reason}}
    end
  end

  defp write_auth_file(_state, _kind, _key), do: :ok
end
