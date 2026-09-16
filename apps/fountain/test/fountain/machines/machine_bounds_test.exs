defmodule Fountain.Machines.MachineBoundsTest do
  @moduledoc """
  The three timeouts a destroy sits between, pinned at their **defaults**
  (ADR 0058 stage 5).

  `destroy_test.exs` drives the wait with a short bound injected by the test,
  which proves the mechanism and pins no number. These are the numbers every
  production call site actually runs with — none of the three passes
  `:busy_wait_ms` or `:lease_ttl_ms` — and the ordering between them is a
  correctness property, not a preference:

      Destroy.busy_wait_ms  <  Machine.destroy_timeout_ms  <  conversation_call_timeout_ms
             5s                        20s                            30s

  Read right to left. A `ConversationServer`'s client gives up at
  `conversation_call_timeout_ms` and answers `{:error, :provisioning}` — a word
  that means the opposite of what a terminate was doing — so anything the
  server does inside one `handle_call` has to finish inside that. The owner's
  call timeout has to be under it for the same reason, and over the protocol's
  own wait, or a destroy that waits its full wait races the timeout and a
  success is reported as a failure. And the protocol's wait has to be the
  smallest, because on the dead-server path it runs in the web request itself.

  The lease TTL is the odd one out on purpose: it bounds how long a *holder*
  may hold the machine, not how long a *waiter* waits, and it was once the same
  number as the wait. That conflation is what made a `DELETE` hang for a
  minute.
  """

  use ExUnit.Case, async: true

  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Machine

  # The ceiling `ConversationServer.call_server/2` reads. Duplicated rather than
  # imported because the point is to pin the relationship to *that* number, and
  # a test that read it through the same default would agree with itself.
  @conversation_call_timeout_ms 30_000

  test "the caller-facing bounds are ordered, with real headroom between them" do
    assert Destroy.busy_wait_ms() == 5_000
    assert Machine.destroy_timeout_ms() == 20_000

    assert Destroy.busy_wait_ms() < Machine.destroy_timeout_ms(),
           "a destroy that waits its own bound would race the owner's call timeout, " <>
             "and a completed destroy would be reported to its caller as a failure"

    assert Machine.destroy_timeout_ms() < @conversation_call_timeout_ms,
           "a ConversationServer's client gives up at #{@conversation_call_timeout_ms}ms " <>
             "with {:error, :provisioning}; a destroy must answer before that"

    # Not decoration: 200ms of scheduling slack between two timeouts is what
    # made the first draft's 60s/60s pair race.
    assert Machine.destroy_timeout_ms() - Destroy.busy_wait_ms() >= 5_000
    assert @conversation_call_timeout_ms - Machine.destroy_timeout_ms() >= 5_000
  end

  test "the wait bound is not the lease TTL" do
    # They were the same number, and that is the bug this file exists for: a
    # holder may hold the machine for a minute; a caller must not wait one.
    assert Destroy.lease_ttl_ms() == 60_000

    assert Destroy.busy_wait_ms() < Destroy.lease_ttl_ms(),
           "the waiter's bound must be shorter than the holder's lease"
  end

  test "the application default for the conversation call timeout is what this pins against" do
    assert Application.get_env(:fountain, :conversation_call_timeout_ms, 30_000) ==
             @conversation_call_timeout_ms
  end

  test "no call site overrides the bounds" do
    # The defaults only mean something if nothing in `lib/` passes its own. A
    # test may (and `destroy_test.exs` does) — that is the mechanism check.
    #
    # Five levels to the repository root, the same climb
    # `direct_writes_test.exs` makes from this directory. The first draft
    # climbed four, landed on `apps/`, found neither candidate directory, and
    # scanned nothing at all — a test that passed because it looked at zero
    # files. Hence the count assertion below: an empty scan is the failure
    # mode this check has, so it has to be the loud one.
    root = Path.expand("../../../../..", __DIR__)

    files =
      ([Path.join(root, "apps/fountain/lib"), Path.join(root, "ee/lib")] ++
         Path.wildcard(Path.join(root, "apps/fountain_*/lib")))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
      |> Enum.reject(&String.ends_with?(&1, "machines/destroy.ex"))

    # Not a bare count: the files that could plausibly override a bound are the
    # three sites that call the protocol, so the scan has to be shown to reach
    # *them*. A count alone drifts; this fails the day one of them moves, which
    # is the day to check the scan still covers its new home.
    relative = MapSet.new(files, &Path.relative_to(&1, root))

    for site <- [
          "apps/fountain/lib/fountain/conversations/termination.ex",
          "apps/fountain/lib/fountain/conversations/lifecycle.ex",
          "apps/fountain/lib/fountain/conversations/conversation_server.ex",
          "apps/fountain/lib/fountain/machines/machine.ex"
        ] do
      assert MapSet.member?(relative, site),
             "the scan missed #{site} (#{length(files)} files under #{root}), so an " <>
               "override there would not be seen and this test proves nothing"
    end

    offenders = Enum.filter(files, &(File.read!(&1) =~ ~r/\b(busy_wait_ms|lease_ttl_ms):/))

    assert offenders == [],
           "these pass their own bound, so the defaults above stop being the live " <>
             "numbers: #{inspect(Enum.map(offenders, &Path.relative_to(&1, root)))}"
  end
end
