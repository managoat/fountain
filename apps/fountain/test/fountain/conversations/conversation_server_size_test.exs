defmodule Fountain.Conversations.ConversationServerSizeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  `ConversationServer` only shrinks.

  Tracker #1369 refactors the server by subtraction: each sub-issue moves a
  function family into a module under `Fountain.Conversations.*` and lowers
  `@pin` to the file's new length in the PR that lands on `main` (see below
  for a stack). The pin is the file's line count on `main` at the last move,
  so a change that makes the file longer fails here and has to say why.

  The size ceiling only shrinks: the number
  is not a target, it is a record of where the file is, and the only edit it
  accepts is downward. Lower it when you move something out; never raise it.

  **A stack in flight does not move it.** The pin is the length on `main`, and
  a number measured against a branch is stale the moment any link below it
  grows the file, which is what review rounds do. #1565 lowered it mid-stack to
  the tip's exact length, left zero headroom, and went red two rounds later
  when a fix four PRs down added lines. That lowering was backed out before
  merge. Land the shrink first, then lower the pin in a follow-up, when the
  number has stopped moving.

  That is what this pin is mid-way through. #1749 and #1751 each lowered it
  to their own tip's exact length while the #1766/#1767 campaign was in
  flight below them, which left `main` at 2646 with the file also at 2646 —
  no room for the next line anyone adds, and a campaign already ~68 lines
  over it with nothing red anywhere (#2032). Each of its PRs is green
  against its own base, the merges conflict on nothing, and `count <= @pin`
  only fails at the moment the last one lands.
  """

  # 2223 → 2220. ADR 0058 stage 5a took the server's own destroy out of
  # `terminate_machine/2` — the provider call, the terminal write and the
  # `now/0` helper that was left with no other caller — and moved the fence
  # and the destroy request to `Conversations.Termination`, whose verb they
  # belong to (#2175). The file is 2214 lines on this branch.
  #
  # 2220 is that plus 6 rather than the usual 10: the pin only ever shrinks,
  # and 2214 + 10 would be 2224, above the 2223 it is coming down from. Six
  # lines is thin for a review round, which is the honest state of this file —
  # stages 6-8 take the server's remaining machine writes out and lower it
  # properly. Nothing is stacked below this PR, so the number is not measured
  # against a moving base.
  #
  # 2219 → 2025. ADR 0058 stage 7b took the fresh-provision arm out whole
  # (`Fountain.Conversations.FreshProvision`), which is the shrink stages 5 and
  # 6 kept promising and could not deliver: each of those moved a provider call
  # the server did not make, or added handling for a refusal it had never had to
  # answer, and the two nearly cancelled. This one is different because the
  # thing that moved is a *family* — the bracket's arms are
  # `Fountain.Machines.Provision`'s now, and what is left of the arm is the
  # pipeline, which is a module of its own under `Fountain.Conversations.*`,
  # exactly the shape #1369 asks for.
  #
  # `reattach/6` stays in the server on purpose. It works on a machine that
  # already exists, so it has no bracket around it, and what it does with the
  # state it builds — reattaching a running turn, finishing a runner reconnect —
  # is the server's own business rather than a pipeline.
  #
  # The file is 2005 lines on this branch, so this is that plus twenty. Nothing is
  # stacked below this PR, so the number is not measured against a moving base.
  #
  # 2220 → 2219. ADR 0058 stage 6b moved the idle verdict's
  # "is the machine busy elsewhere" arm into `Lifecycle.idle_machine_action/3`,
  # with the rest of the lifecycle policy (#1376), and gave `park_sandbox/2`
  # the refusals the owner can now answer with. Those two nearly cancel, and
  # they were always going to: the park's *provider call* was never in this
  # file to take out, while the handling of a park that is refused is new work
  # the server has to do. So this is a shrink of one line rather than the ten
  # the brief hoped for, and saying so is better than moving something out to
  # make a number. The server's own `update_sandbox` and
  # `Managoat.Sandbox.destroy` sites are stage 8's, and they are the ones that
  # lower this properly. The file is 2211 lines on this branch.
  @pin 2025

  @server "apps/fountain/lib/fountain/conversations/conversation_server.ex"

  test "the server is no longer than the pin" do
    root = Path.expand("../../../../..", __DIR__)
    lines = root |> Path.join(@server) |> File.read!() |> String.split("\n")
    # `String.split/2` yields one more element than there are newlines, so
    # this is `wc -l` for a file that ends in a newline.
    count = length(lines) - 1

    assert count <= @pin,
           "#{@server} is #{count} lines, over the pin of #{@pin}. " <>
             "The server only shrinks (#1369): move the new code into a " <>
             "Fountain.Conversations.* module rather than raising the pin."
  end
end
