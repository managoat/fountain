defmodule Fountain.Conversations.CodexApproval do
  @moduledoc """
  The codex approval mode a turn's permission policy needs (#2708).

  codex-acp 2.2.2 has four modes, and each one fixes codex's approval policy,
  its reviewer and its sandbox for every turn:

  | Mode | Approval | Reviewer | Sandbox |
  |---|---|---|---|
  | `read-only` | `on-request` | `user` | `readOnly` |
  | `workspace-write` ("Workspace access") | `on-request` | `user` | `workspaceWrite` |
  | `agent` ("Auto review", the default) | `on-request` | `auto_review` | `workspaceWrite` |
  | `agent-full-access` | `never` | — | `dangerFullAccess` |

  In `agent` mode codex's automatic reviewer decides every escalation and
  Fountain is never asked (ADR 0014's 2026-10-15 addendum). `workspace-write`
  is the same sandbox with the client as the reviewer, so an escalation, a
  network request or a write outside the workspace reaches the permission
  policy, and writes inside the workspace still run. codex-acp 1.10.0 called
  that mode `read-only`; 2.0.0 renamed it and gave the name to a mode whose
  sandbox really is read-only, which Fountain does not choose.

  A policy with any verdict other than `auto_allow` needs codex to ask, so the
  adapter is spawned with `INITIAL_AGENT_MODE=workspace-write`, which it reads
  for every session it opens, new, resumed or loaded. Fountain's value
  replaces an environment's own `INITIAL_AGENT_MODE`, `agent-full-access`
  included: that mode never asks, and the policy would govern nothing. A
  policy that allows everything adds nothing, so codex keeps its default
  `agent` mode, or the environment's choice. ADR 0014's 2026-10-15 (#2708)
  addendum has the design.
  """

  @mode_var "INITIAL_AGENT_MODE"
  @asking_mode "workspace-write"

  @doc "Whether `policy` (an effective policy) has a verdict codex must ask about."
  @spec asks?(map() | nil) :: boolean()
  def asks?(policy) when is_map(policy),
    do: Enum.any?(policy, fn {_key, verdict} -> verdict != "auto_allow" end)

  def asks?(_policy), do: false

  @doc """
  The adapter env `policy` adds for `runtime`: the asking mode for codex under
  a policy that asks, nothing otherwise.
  """
  @spec env(String.t(), map() | nil) :: [{String.t(), String.t()}]
  def env("codex", policy), do: if(asks?(policy), do: [{@mode_var, @asking_mode}], else: [])
  def env(_runtime, _policy), do: []

  @doc """
  `env` with `approval_env` applied. A non-empty one replaces every
  `INITIAL_AGENT_MODE` already in `env`, so the adapter reads Fountain's
  whichever duplicate it would pick.
  """
  @spec put_env([{String.t(), String.t()}], [{String.t(), String.t()}]) ::
          [{String.t(), String.t()}]
  def put_env(env, []), do: env

  def put_env(env, approval_env),
    do: Enum.reject(env, &match?({@mode_var, _}, &1)) ++ approval_env
end
