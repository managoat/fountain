defmodule Fountain.AuditActorVocabularyTest do
  @moduledoc """
  The actor vocabulary is closed (ADR 0013).

  `actor` started life hardcoded to `"api"`, and the #540 campaign replaced
  that with a set of strings written at ~30 call sites.
  Nothing held the set together: billing composed `system:admin` for an
  action a person took, one mix task spelled its worker `lifecycle-verify`
  while the rest use snake_case, and the unauthenticated routes recorded a
  bare `"system"` for people clicking links in their mail client.

  A vocabulary that only exists as a habit drifts. This test is the shape
  check; the ADR is the decision.
  """

  use ExUnit.Case, async: true

  # The whole list. Adding to it is an ADR amendment, not a call-site choice.
  @plain ~w(self ui api sprite admin)

  # `admin:<operator_id>` (account deletion) and `system:<worker>`, either
  # literal or interpolated at the call site.
  @qualified ~r/^(admin|system):(\#\{[^}]+\}|[a-z][a-z0-9_]*)$/

  @adr Path.expand("../../../../decisions/0013-audit-trail.md", __DIR__)

  defp lib_files do
    __DIR__ |> Path.expand() |> Path.join("../../lib/**/*.ex") |> Path.wildcard()
  end

  defp actor_literals do
    for path <- lib_files(),
        [_, actor] <- Regex.scan(~r/actor: "([^"]+)"/, File.read!(path)),
        do: {Path.relative_to_cwd(path), actor}
  end

  test "every actor written in lib/ is in the vocabulary" do
    literals = actor_literals()

    # Guard the guard: a regex that stopped matching would make every
    # assertion below vacuous.
    assert length(literals) > 20,
           "found only #{length(literals)} actor literals — the scan is probably broken"

    for {path, actor} <- literals do
      assert actor in @plain or Regex.match?(@qualified, actor), """
      #{path} records actor #{inspect(actor)}, which is not in the vocabulary.

      The members are #{Enum.join(@plain, ", ")}, admin:<operator_id> and
      system:<worker> (snake_case, named after the module doing the work).
      Adding one is an amendment to decisions/0013-audit-trail.md.
      """
    end
  end

  test "no call site records a bare \"system\"" do
    # `attribution/2` derives "system" when a request has no principal, which
    # only happens on the unauthenticated pipelines — login, registration,
    # POST /api/auth/token, email verification. Every one of those is a person,
    # and the call site knows which surface they came through, so it says so.
    # A "system" row means somebody forgot the override.
    for {path, actor} <- actor_literals() do
      refute actor == "system",
             "#{path} records a bare \"system\" actor — pass the surface explicitly (ADR 0013)"
    end
  end

  test "the ADR names every member of the vocabulary" do
    # The code and the decision drift apart quietly otherwise: adding a member
    # above without arguing for it in the ADR is exactly the move this is
    # meant to make hard.
    adr = File.read!(@adr)

    for member <- @plain ++ ["admin:<operator_id>", "system:<worker>"] do
      assert String.contains?(adr, member),
             "decisions/0013-audit-trail.md does not mention the #{inspect(member)} actor"
    end
  end
end
