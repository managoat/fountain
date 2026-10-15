defmodule Managoat.Sandbox.Session do
  @moduledoc """
  A normalized record of a detachable session living inside a sandbox.

  Deliberately carries no `is_active` flag: a detached session reports
  inactive while nobody is connected, and filtering on it would skip exactly
  the sessions reattach exists to recover. Leaving the field out makes that
  mistake unrepresentable (see `docs/integrations/sprites-contract.md`,
  "Sessions").
  """

  defstruct [:id, :command, :created_at, :last_activity_at, tty: false]

  @type t :: %__MODULE__{
          id: String.t(),
          command: String.t() | nil,
          created_at: DateTime.t() | nil,
          last_activity_at: DateTime.t() | nil,
          tty: boolean()
        }
end
