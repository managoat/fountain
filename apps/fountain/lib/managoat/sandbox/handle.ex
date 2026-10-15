defmodule Managoat.Sandbox.Handle do
  @moduledoc """
  A provider-tagged reference to a sandbox.

  Handles are rebuilt from persistence (the `sandboxes` row) on every wake
  and reattach, so `Managoat.Sandbox.build_handle/2` must be pure and every
  operation must work on a handle whose `private` is `nil` — adapters
  rebuild whatever connection state they need from `name` lazily.

  `private` is adapter-owned and opaque to callers. It is excluded from
  `inspect/1` because the Sprites adapter keeps a client struct there that
  embeds the platform bearer token — a handle in a log line must never leak
  it.

  `instance_id` is opaque provider control metadata, populated by `create_new`.
  It is not an authorization token or a conditional-write guarantee. Hosts must
  persist it with their operation intent; rebuilding from a name cannot recover
  the identity of an earlier incarnation.
  """

  @derive {Inspect, only: [:provider, :name]}
  @enforce_keys [:provider, :name]
  defstruct [:provider, :name, :private, :instance_id]

  @type t :: %__MODULE__{
          provider: atom(),
          name: String.t(),
          private: term(),
          instance_id: String.t() | nil
        }
end
