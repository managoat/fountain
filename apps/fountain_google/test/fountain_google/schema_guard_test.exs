defmodule FountainGoogle.SchemaGuardTest do
  @moduledoc """
  The schema guard can see this extension (#1536).

  Every check is in `FountainWeb.ExtensionSchemaGuardCase`. This extension
  documents no operation (its one route is a JSON-RPC transport), so the
  resolution checks walk an empty set today; the case is here so that the day
  an operation is added, its responses are validated like every other
  extension's rather than skipped in silence.
  """
  use FountainWeb.ExtensionSchemaGuardCase, extension: FountainGoogle.Extension
end
