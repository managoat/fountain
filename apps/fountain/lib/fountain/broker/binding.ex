defmodule Fountain.Broker.Binding do
  @moduledoc """
  One host a brokered credential is substituted on: the broker replaces the
  key's placeholder wherever it appears in a request to `host` (a header
  value, the path or the query).

  Only the runtime's inference credentials carry bindings, one per provider
  host, built by `Fountain.Broker.split_inference/2`. Tenant-configured
  bindings (ADR 0019 gate 1b) were removed on 2026-10-13; the GitHub pair is
  the built-in catalog, not a binding.
  """

  @enforce_keys [:key, :host]
  defstruct [:key, :host]

  @type t :: %__MODULE__{key: String.t(), host: String.t()}
end
