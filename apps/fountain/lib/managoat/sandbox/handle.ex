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
  """

  @derive {Inspect, only: [:provider, :name]}
  @enforce_keys [:provider, :name]
  defstruct [:provider, :name, :private]

  @type t :: %__MODULE__{
          provider: atom(),
          name: String.t(),
          private: term()
        }
end
