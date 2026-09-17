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

  ## And the four a park sits between (stage 6b)

      Park.busy_wait_ms  <  Machine.park_timeout_ms  <  Park.lease_ttl_ms
            5s                      60s                      120s

  A park's ceiling is **not** `conversation_call_timeout_ms`, and that is the
  one thing about this row worth saying twice: neither caller is a request.
  The conversation server's park runs inside the server itself, from its own
  `:lifecycle_check` message, so no client of `call_server/2` is waiting on it;
  the reaper's runs in an Oban job. What a park does have above it is its own
  lease, because a caller that outlives the lease it is waiting on would be
  waiting for work another owner is already entitled to take over — which is
  the same conflation as the destroy row, one step along.
  """

  use ExUnit.Case, async: true

  alias Fountain.Conversations.ProvisionWatchdog
  alias Fountain.Machines.Admission
  alias Fountain.Machines.Binding
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Park
  alias Fountain.Machines.Provision
  alias Fountain.Machines.Renewal
  alias Fountain.Machines.Resume

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

  test "a park's bounds are ordered, and are not the destroy's" do
    assert Park.busy_wait_ms() == 5_000
    assert Machine.park_timeout_ms() == 60_000
    assert Park.lease_ttl_ms() == 120_000

    assert Park.busy_wait_ms() < Machine.park_timeout_ms(),
           "a park that waits its own bound would race the owner's call timeout, and a " <>
             "completed park would be reported to its caller as a failure"

    assert Machine.park_timeout_ms() < Park.lease_ttl_ms(),
           "a caller that outlives the lease is waiting on work another owner may take over"

    assert Park.busy_wait_ms() == Destroy.busy_wait_ms(),
           "the two protocols make a caller wait different amounts for the same condition"

    assert Park.lease_ttl_ms() > Destroy.lease_ttl_ms(),
           "a park holds the machine for a checkpoint and a suspend, which is longer than " <>
             "a destroy's one round trip; a TTL that expires mid-park invites a takeover " <>
             "of work that is not abandoned"
  end

  test "a resume's bounds are ordered, and are the destroy's" do
    # A resume is one provider round trip, like a destroy, and unlike a park has
    # no checkpoint in front of it — so it takes the destroy's numbers outright
    # rather than a third set nobody can keep in their head. Asserted as
    # equality, not as an ordering: the day one of them moves alone is the day
    # somebody has to say why the two operations stopped being the same shape.
    assert Resume.busy_wait_ms() == Destroy.busy_wait_ms()
    assert Resume.lease_ttl_ms() == Destroy.lease_ttl_ms()
    assert Machine.resume_timeout_ms() == Machine.destroy_timeout_ms()

    assert Resume.busy_wait_ms() < Machine.resume_timeout_ms(),
           "a caller that gives up before the protocol's own wait would report a refusal " <>
             "that has not happened yet"

    assert Machine.resume_timeout_ms() < Resume.lease_ttl_ms(),
           "a caller that outlives the lease would be waiting on work another owner is " <>
             "entitled to take over"

    assert Machine.resume_timeout_ms() - Resume.busy_wait_ms() >= 5_000
    assert Resume.lease_ttl_ms() - Machine.resume_timeout_ms() >= 5_000
  end

  test "a resume's caller is a request, so its ceiling sits under the client's" do
    # The difference from a park, and the reason the two are not the same
    # number: a prompt that wakes a parked conversation runs on the request
    # process, so this bound is what a person waits before the page says
    # something. A resume slower than it is not abandoned — `Machines.Renewal`
    # keeps its lease alive and the owner finishes it — so the caller is told
    # `sandbox_unavailable` and the retry finds the machine up.
    assert Machine.resume_timeout_ms() < @conversation_call_timeout_ms
    assert Machine.park_timeout_ms() > @conversation_call_timeout_ms
  end

  test "a park's call timeout is deliberately over the ConversationServer client ceiling" do
    # Not an oversight and not an ordering to fix. `park_sandbox/2` runs inside
    # the server, reached from its own `:lifecycle_check`, so nothing is
    # waiting at `conversation_call_timeout_ms` for it to answer — and a park
    # that had to finish inside 30s would give up on a slow home checkpoint and
    # destroy the machine instead. A destroy is the one that runs on a request
    # process, which is why it has the tighter ceiling.
    assert Machine.park_timeout_ms() > @conversation_call_timeout_ms
    assert Machine.destroy_timeout_ms() < @conversation_call_timeout_ms
  end

  test "the application default for the conversation call timeout is what this pins against" do
    assert Application.get_env(:fountain, :conversation_call_timeout_ms, 30_000) ==
             @conversation_call_timeout_ms
  end

  test "a provision's ladder, and why its lease is not what bounds it" do
    # A provision has the same two bounds as the other three and reads them
    # differently, because it is the one operation here that legitimately runs
    # for minutes. The lease TTL bounds a provision that has *stopped*, not one
    # that is slow: `Machines.Renewal` extends it for as long as the work is
    # making progress, up to `ProvisionWatchdog.deadline_ms/0`.
    assert Provision.busy_wait_ms() == Destroy.busy_wait_ms()
    assert Provision.lease_ttl_ms() == Destroy.lease_ttl_ms()

    # There is no `Machine.provision_timeout_ms/0` and there is not meant to be:
    # the bracket runs inline on its caller whichever way the gate is set, so
    # there is no `GenServer.call` to put a ceiling on. See
    # `Fountain.Machines.Provision`'s moduledoc.
    #
    # `Code.ensure_loaded!/1` first, because `function_exported?/3` answers
    # `false` for an unloaded module and an `alias` does not load one — so
    # without it this test passed for the wrong reason, and only happened to be
    # safe because a *different* file adds `Mimic.copy(Machine)` (round 1,
    # behaviour review).
    Code.ensure_loaded!(Machine)
    assert function_exported?(Machine, :provision, 3), "the scan below proves nothing"
    refute function_exported?(Machine, :provision_timeout_ms, 0)

    # And the watchdog's own wait for the lease, which is the one override in
    # `lib/`. It has to be clear of the TTL, or it would arrive while the lease
    # it is waiting for could still legitimately be held.
    assert ProvisionWatchdog.retire_wait_ms() > Provision.lease_ttl_ms()
    assert ProvisionWatchdog.lapse_grace_ms() > Provision.lease_ttl_ms()
  end

  # The two bound-shaped calls `lib/` makes on purpose, each spelled exactly as
  # the file makes it. The scan below removes these strings from every file's
  # content before it looks, so a file is never exempt — only the one call is.
  #
  # Stage 7b exempted `provision_watchdog.ex` and `fresh_provision.ex` wholesale
  # and pinned each with a "passes a named accessor" assertion beside it. The 7b
  # protocol review ran the shape that replaces both: a literal
  # `lease_ttl_ms: 1_000` planted next to the `deadline_ms:` call passed the
  # exempted file and fails this one. Stripping the call rather than the file
  # also makes the containment pin redundant: an entry here that no file makes
  # any more strips nothing, and the day that call becomes a literal the scan
  # names it.
  @known_good_bound_calls [
    # `ProvisionWatchdog` waits longer than five seconds for a lease it has
    # already waited half an hour for; giving up early would leave a stuck
    # server alive with a live row, the #394 ordering inverted. Pinned by value
    # in "a provision's ladder" above.
    "busy_wait_ms: @retire_wait_ms",
    # The provision bracket's renewal window is `ProvisionWatchdog.deadline_ms/0`
    # rather than `Renewal`'s ten TTLs (stage 7b, behaviour change 8).
    "deadline_ms: ProvisionWatchdog.deadline_ms()"
  ]

  # A bound passed as an option, in any of the three spellings a protocol takes.
  # `deadline_ms` joined the two in stage 7b: a `deadline_ms:` on a destroy, a
  # park or a resume would silently replace `Renewal`'s ten-TTL hard stop, and
  # nothing else would notice — which is the failure mode this scan is for.
  #
  # `admit_timeout_ms` joined in stage 8a round 1: it is the test seam for the
  # owner-side deadline on an admission, and a `lib/` caller passing it would
  # replace `Machine.admit_timeout_ms/0` for that call with nothing noticing.
  #
  # `attach_timeout_ms`, `detach_timeout_ms` and `resume_timeout_ms` joined in
  # stage 8b, each the test seam for the deadline its owner message carries.
  @bound_option ~r/\b(busy_wait_ms|lease_ttl_ms|deadline_ms|admit_timeout_ms|attach_timeout_ms|detach_timeout_ms|resume_timeout_ms):/

  test "an admission's ladder, and why it has no lease to sit under" do
    # An admission is one transaction that may first wait out a live lease, so
    # it has a waiter's bound and a call timeout, and they take the destroy's
    # numbers for the destroy's reasons: the caller is a request (the prompt's
    # `handle_call`), so the ceiling sits under the client's.
    assert Admission.busy_wait_ms() == Destroy.busy_wait_ms()
    assert Machine.admit_timeout_ms() == Machine.destroy_timeout_ms()

    assert Admission.busy_wait_ms() < Machine.admit_timeout_ms(),
           "a caller that gives up before the protocol's own wait would report a refusal " <>
             "that has not happened yet"

    assert Machine.admit_timeout_ms() < @conversation_call_timeout_ms,
           "a ConversationServer's client gives up at #{@conversation_call_timeout_ms}ms; an " <>
             "admission must answer before that"

    assert Machine.admit_timeout_ms() - Admission.busy_wait_ms() >= 5_000
    assert @conversation_call_timeout_ms - Machine.admit_timeout_ms() >= 5_000

    # And there is no third rung: an admission takes no lease, so it has no TTL
    # for the timeout to sit under and there is not meant to be one. See
    # `Fountain.Machines.Admission`'s moduledoc for why. `Code.ensure_loaded!/1`
    # first, and a positive control, for the reason the provision case above
    # gives.
    Code.ensure_loaded!(Admission)
    assert function_exported?(Admission, :busy_wait_ms, 0), "the refutation below proves nothing"
    refute function_exported?(Admission, :lease_ttl_ms, 0)
  end

  test "the binding's ladders, and the early takeover's headroom (stage 8b)" do
    # An attach is one transaction with no wait beneath it — a live lease
    # refuses it at once, stage 6a's decision for the attach door — so its
    # one bound is the request behind it, and it takes the destroy's number
    # under the client's ceiling. A detach waits out a live lease first, for
    # `Binding.busy_wait_ms/0`, and sits above that wait the way a destroy sits
    # above its own.
    assert Machine.attach_timeout_ms() == Machine.destroy_timeout_ms()
    assert Machine.detach_timeout_ms() == Machine.destroy_timeout_ms()
    assert Binding.busy_wait_ms() == Destroy.busy_wait_ms()

    assert Binding.busy_wait_ms() < Machine.detach_timeout_ms(),
           "a caller that gives up before the protocol's own wait would report a refusal " <>
             "that has not happened yet"

    assert Machine.detach_timeout_ms() - Binding.busy_wait_ms() >= 5_000
    assert Machine.attach_timeout_ms() < @conversation_call_timeout_ms
    assert Machine.detach_timeout_ms() < @conversation_call_timeout_ms

    # Neither takes a lease, so neither has a TTL to sit under; a positive
    # control, for the reason the provision case gives.
    Code.ensure_loaded!(Binding)
    assert function_exported?(Binding, :busy_wait_ms, 0), "the refutation below proves nothing"
    refute function_exported?(Binding, :lease_ttl_ms, 0)

    # The early takeover (`Lease.absent_node_headroom_ms/0`): a holder that is
    # not a connected node is taken over once its remaining lease is under this.
    # A live renewer renews every `Renewal.divisor/0`th of its TTL, so a single
    # missed renewal leaves it sitting at exactly one renew interval — a line it
    # touches, not one it stays above. The headroom must therefore sit
    # **strictly under** one renew interval of the *shortest* TTL any protocol
    # takes, with margin for the renewer's own latency, or one slow renewal
    # evicts a live holder (round 1, protocol review). Half an interval is the
    # margin chosen: one whole missed renewal, outright.
    #
    # That margin only buys what it claims because `Renewal` schedules each
    # attempt from the slot it was due in rather than from the last one's
    # return (round 3); otherwise a failing attempt's own duration came out of
    # this headroom too, and a 12 s stall at TTL 60 was enough. The cadence is
    # `renewal_test.exs`'s to drive; what is pinned here is the number.
    shortest_ttl =
      Enum.min([
        Destroy.lease_ttl_ms(),
        Park.lease_ttl_ms(),
        Resume.lease_ttl_ms(),
        Provision.lease_ttl_ms()
      ])

    renew_interval = div(shortest_ttl, Renewal.divisor())

    assert Lease.absent_node_headroom_ms() == 10_000
    assert Lease.absent_node_headroom_ms() < renew_interval
    assert Lease.absent_node_headroom_ms() <= div(renew_interval, 2)
    assert Renewal.divisor() == 3
  end

  test "no call site overrides the bounds" do
    # The defaults only mean something if nothing in `lib/` passes its own. A
    # test may (and `destroy_test.exs` does) — that is the mechanism check.
    #
    # Five levels to the repository root, the same climb
    # `direct_writes_test.exs` makes from this directory. The first draft
    # climbed four, landed on `apps/`, found neither candidate directory, and
    # scanned nothing at all — a test that passed because it looked at zero
    # files. Hence the reach assertion below: an empty scan is the failure
    # mode this check has, so it has to be the loud one.
    root = Path.expand("../../../../..", __DIR__)

    files =
      ([Path.join(root, "apps/fountain/lib"), Path.join(root, "ee/lib")] ++
         Path.wildcard(Path.join(root, "apps/fountain_*/lib")))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))

    # Not a bare count: the files that could plausibly override a bound are the
    # sites that call a protocol, so the scan has to be shown to reach *them* —
    # and, since stage 8a, the protocol modules themselves, which used to be
    # excluded and now are not. A count alone drifts; this fails the day one of
    # them moves, which is the day to check the scan still covers its new home.
    relative = MapSet.new(files, &Path.relative_to(&1, root))

    for site <- [
          "apps/fountain/lib/fountain/conversations/termination.ex",
          "apps/fountain/lib/fountain/conversations/lifecycle.ex",
          "apps/fountain/lib/fountain/conversations/conversation_server.ex",
          "apps/fountain/lib/fountain/conversations/provision_watchdog.ex",
          "apps/fountain/lib/fountain/conversations/fresh_provision.ex",
          "apps/fountain/lib/fountain/workers/sandbox_reaper.ex",
          "apps/fountain/lib/fountain/machines/machine.ex",
          "apps/fountain/lib/fountain/machines/destroy.ex",
          "apps/fountain/lib/fountain/machines/park.ex",
          "apps/fountain/lib/fountain/machines/resume.ex",
          "apps/fountain/lib/fountain/machines/provision.ex",
          "apps/fountain/lib/fountain/machines/admission.ex",
          "apps/fountain/lib/fountain/machines/binding.ex",
          "apps/fountain/lib/fountain/team.ex"
        ] do
      assert MapSet.member?(relative, site),
             "the scan missed #{site} (#{length(files)} files under #{root}), so an " <>
               "override there would not be seen and this test proves nothing"
    end

    offenders =
      Enum.filter(files, fn file ->
        file |> File.read!() |> strip_known_good_calls() |> String.match?(@bound_option)
      end)

    assert offenders == [],
           "these pass their own bound, so the defaults above stop being the live " <>
             "numbers: #{inspect(Enum.map(offenders, &Path.relative_to(&1, root)))}"
  end

  # The scan's own positive control: the strip has to remove the two calls it
  # names and nothing else, or a broken strip would either hide a literal or
  # flag the two known-good files for ever.
  test "the strip removes exactly the two known-good calls" do
    planted = """
    Renewal.around(id, epoch, ttl, fun,
      deadline_ms: ProvisionWatchdog.deadline_ms()
    )
    Machine.fail_provision(id, busy_wait_ms: @retire_wait_ms, actor: "x")
    """

    refute planted |> strip_known_good_calls() |> String.match?(@bound_option)

    # The shape the 7b review planted: a literal beside the named call, in a
    # file the old scan exempted.
    assert (planted <> "    lease_ttl_ms: 1_000\n")
           |> strip_known_good_calls()
           |> String.match?(@bound_option)

    # And a literal in the position the named call occupies.
    assert "deadline_ms: 1_800_000" |> strip_known_good_calls() |> String.match?(@bound_option)
  end

  defp strip_known_good_calls(content) do
    Enum.reduce(@known_good_bound_calls, content, &String.replace(&2, &1, ""))
  end
end
