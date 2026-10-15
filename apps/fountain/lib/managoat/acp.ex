defmodule Managoat.ACP do
  @moduledoc """
  The client side of the Agent Client Protocol, as a session that outlives
  the turn.

  [ACP](https://agentclientprotocol.com) is JSON-RPC 2.0 over newline-delimited
  JSON between a *client* (an editor, or a platform such as Fountain) and an
  *agent* (claude-agent-acp, codex-acp, gemini, opencode). This package is the
  client. It is not a schema library: messages are maps, the protocol's
  wire names are used as they are, and what the package adds is the part of
  a client that the spec leaves to you and that a real deployment cannot do
  without.

  | Module | Role |
  |---|---|
  | `Managoat.ACP.Peer` | One connection, for as many turns as its owner sends it. Drives `initialize` → `session/new` / `session/resume` / `session/load` → `session/prompt`, answers the agent's requests, and reports to its owner as `{:acp, ref, payload}`. Reattaches to a turn already in flight, discards a `session/load` replay, and keeps a permission request open for a human. |
  | `Managoat.ACP.Transport` | The seam: a `writer` function for outbound frames. Inbound bytes reach the peer through `Peer.stdout/2`. |
  | `Managoat.ACP.Protocol` | Framing and JSON-RPC encoding. Pure. |
  | `Managoat.ACP.Permissions` | What answers `session/request_permission`: a policy map matched most-specific-first, a narrow-never-widen merge, and the fail-closed rules for answering from the options the agent offered. |
  | `Managoat.ACP.Blocks` | `session/update` notifications and permission requests as the block maps a transcript renders. |
  | `Managoat.ACP.Usage` | The end-of-turn token figure, normalised from the `session/prompt` result. |
  | `Managoat.ACP.Tracer` | `tool_call` / `tool_call_update` as OpenTelemetry spans, for every runtime. |
  | `Managoat.ACP.Testing.ScriptedAgent` | An agent inside the BEAM that answers the handshake and streams scripted updates, for a host's tests. |

  The README carries the owner message contract and the comparison against
  the two ACP packages on hex.
  """
end
