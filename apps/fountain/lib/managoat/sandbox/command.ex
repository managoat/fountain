defmodule Managoat.Sandbox.Command do
  @moduledoc """
  A provider-tagged handle to a running (or attached) streaming command.

  `ref` is the correlation key: every message the adapter delivers to the
  owner process carries a map with this `ref` (see the message contract in
  `Managoat.Sandbox`), and callers store it to match frames in
  `handle_info/2` heads. Consumers must match `%{ref: ref}` — never an
  adapter's internal struct.

  `private` is adapter-owned (the Sprites adapter keeps the SDK's command
  struct there) and opaque to callers.
  """

  @derive {Inspect, only: [:provider, :ref]}
  @enforce_keys [:provider, :ref]
  defstruct [:provider, :ref, :private]

  @type t :: %__MODULE__{
          provider: atom(),
          ref: term(),
          private: term()
        }
end
