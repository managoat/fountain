defmodule Managoat.Sandbox.NetworkPolicy do
  @moduledoc """
  An intent-level, default-deny egress policy.

  `allow` is the complete list of domains the sandbox may reach; everything
  else is denied. **`allow: []` means deny all egress**, not "no policy" —
  the intent is unambiguous here precisely because at least one provider
  (Sprites) treats an empty rule list as no-enforcement, and translating
  the fail-open quirk is the adapter's job, not the caller's.
  """

  @enforce_keys [:allow]
  defstruct [:allow]

  @type t :: %__MODULE__{allow: [String.t()]}
end
