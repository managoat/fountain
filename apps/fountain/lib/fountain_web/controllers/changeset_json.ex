defmodule FountainWeb.ChangesetJSON do
  @moduledoc """
  A failed changeset, as the API renders it.

  Two keys, and both are load-bearing (#1431):

      {"error": "validation_failed",
       "errors": {"name": ["can't be blank"]}}

  `errors` is the field detail, keyed by field, which is the only useful thing
  about a validation failure and what `ValidationError.fieldErrors` reads in
  every SDK.

  `error` is the code every other Fountain error carries. A 422 is not always a
  validation failure — `FountainWeb.FallbackController` renders sixteen coded
  refusals with that status, `%{error: "vault_not_allowed", message: ...}` and
  the like — so before this, one status meant two incompatible shapes and an
  operation's declared 422 schema could only ever describe one of them. With a
  code here as well, every 422 in the API carries `error`, a client never has
  to branch on which kind it got, and the one `Error` schema every error
  status declares (#2324) is satisfied by a validation body.

  `FountainWeb.Plugs.CastRenderError` renders the same two keys for a request
  the OpenAPI cast rejects, so the shape does not depend on which layer caught
  the problem either.
  """

  @code "validation_failed"

  def error(%{changeset: changeset}) do
    %{error: @code, errors: translate(changeset)}
  end

  defp translate(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
