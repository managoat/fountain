defmodule Fountain.Conversations.BrokerCaInstallSpansTest do
  @moduledoc """
  The split of `broker_ca_install` into its five host spans (#2906).

  The ticket measured one boundary of 0.81–1.32 s and could not say which of
  certificate derivation, the trust-store exec, the relay's script or the
  relay's readiness poll it was. These tests pin the shape that answers it:
  five serial children, fully inside the parent, each carrying the sandbox's
  own clock where the sandbox has one, so parent-minus-children is the
  provider round trip rather than an unexplained remainder.

  Mimic stubs run global here, and the OTel exporter is a process-wide
  setting, so this module is `async: false` like the other broker tests.
  """
  use Fountain.DataCase, async: false
  use Mimic

  require Record
  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias Fountain.Broker
  alias Fountain.Conversations.Egress
  alias Managoat.Sandbox.Handle

  @session %{vault: "c-test", token: "av_sess_conv", expires_at: nil}
  @handle %Handle{provider: :sprites, name: "s"}

  # What a fresh provision's two scripts echo: the append branch of the
  # trust store, and a relay that had to be spawned. Each CA phase is its
  # wall figure, then the monotonic elapsed that checks it (#2911).
  @ca_output """
  __MANAGOAT_BROKER__ ca_lock_wait 3 0
  __MANAGOAT_BROKER__ ca_verify 31 30
  __MANAGOAT_BROKER__ ca_reused 0
  __MANAGOAT_BROKER__ ca_rebuild 0
  __MANAGOAT_BROKER__ ca_trust 88 90
  __MANAGOAT_BROKER__ ca_sudoers 35 40
  __MANAGOAT_BROKER__ ca_total 157 160
  """

  @relay_output """
  __MANAGOAT_BROKER__ relay_boot 38
  __MANAGOAT_BROKER__ relay_probe 5
  __MANAGOAT_BROKER__ relay_restart 0
  __MANAGOAT_BROKER__ relay_spawn 9
  __MANAGOAT_BROKER__ relay_warm 0
  __MANAGOAT_BROKER__ relay_polls 3
  __MANAGOAT_BROKER__ relay_ready 151
  __MANAGOAT_BROKER__ relay_total 166
  """

  setup do
    :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:fountain, :provision_step, :stop],
      fn _name, measurements, metadata, _ -> send(test, {:step, metadata, measurements}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(id)
      :gen_statem.call(:otel_simple_processor_global, {:set_exporter, :none})
    end)

    stub(Broker, :proxy_url, fn -> "https://broker.example:443" end)
    stub(Broker, :ca_pem, fn -> {:ok, "PEM"} end)
    {:ok, user: insert_verified_user()}
  end

  # Exactly the wrapper `FreshProvision.write_sandbox_config/5` puts around
  # this work, so the children are measured against the same parent
  # production reports.
  defp install_under_parent(conv_id) do
    metadata = %{conv_id: conv_id, step: "broker_ca_install", provider: :sprites}

    Fountain.Telemetry.span([:provision_step], metadata, fn ->
      result = Egress.install_ca(@session, @handle, conv_id)
      outcome = if match?({:error, _}, result), do: :failed, else: :ok
      {result, Map.put(metadata, :outcome, outcome)}
    end)
  end

  defp steps do
    for _ <- 1..6 do
      assert_receive {:step, metadata, measurements}, 5_000
      {metadata.step, metadata, measurements}
    end
  end

  defp steps_until(last) do
    Stream.repeatedly(fn ->
      assert_receive {:step, metadata, measurements}, 5_000
      {metadata.step, metadata, measurements}
    end)
    |> Enum.reduce_while([], fn {step, _, _} = recorded, acc ->
      if step == last,
        do: {:halt, Enum.reverse([recorded | acc])},
        else: {:cont, [recorded | acc]}
    end)
  end

  defp spans do
    for _ <- 1..6 do
      assert_receive {:span, recorded}, 5_000
      recorded
    end
  end

  defp succeeding_sandbox do
    stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)

    stub(Managoat.Sandbox.Sprites, :exec, fn
      _h, "bash", _args, _opts -> {:ok, @ca_output, 0}
      _h, "flock", _args, _opts -> {:ok, @relay_output, 0}
    end)
  end

  test "the step splits into the five named phases, in provisioning order", %{user: user} do
    conv = insert_conversation(user_id: user.id)
    succeeding_sandbox()

    assert :ok = install_under_parent(conv.id)

    # The order is the order of the work, and it is still strictly serial:
    # this PR measures the split, it does not parallelise CA and relay.
    assert Enum.map(steps(), &elem(&1, 0)) ==
             ~w(ca_pem ca_write ca_exec relay_write relay_exec broker_ca_install)
  end

  test "every child is a child of the parent, and fits inside it", %{user: user} do
    conv = insert_conversation(user_id: user.id)
    succeeding_sandbox()

    assert :ok = install_under_parent(conv.id)
    recorded = spans()

    # The parent ends last, because every child runs inside it.
    {children, [parent]} = Enum.split(recorded, 5)
    assert Enum.all?(recorded, &(span(&1, :name) == "fountain.provision_step"))
    assert Enum.all?(children, &(span(&1, :parent_span_id) == span(parent, :span_id)))
    assert Enum.all?(recorded, &(span(&1, :trace_id) == span(parent, :trace_id)))

    # Containment is what makes the arithmetic in
    # `scripts/load-test/README.md` legitimate: the children are serial and
    # nested, so their durations do sum, and parent-minus-children is the
    # work the parent has that they do not. Without this they could overlap
    # and the remainder would mean nothing — the mistake #2906's review
    # notes call out in the original reconstruction.
    for child <- children do
      assert span(child, :start_time) >= span(parent, :start_time)
      assert span(child, :end_time) <= span(parent, :end_time)
    end

    children_ns = Enum.sum(Enum.map(children, &(span(&1, :end_time) - span(&1, :start_time))))
    assert children_ns <= span(parent, :end_time) - span(parent, :start_time)
  end

  test "the exec children carry the sandbox's own clocks and which branch ran", %{user: user} do
    conv = insert_conversation(user_id: user.id)
    succeeding_sandbox()

    assert :ok = install_under_parent(conv.id)
    by_step = Map.new(steps(), fn {step, metadata, _} -> {step, metadata} end)

    # `ca_rebuild = 0` is the ticket's validation criterion: the fresh path
    # takes the ~130 ms append branch, not the 1.1–2.0 s rebuild.
    assert %{"ca_rebuild" => 0, "ca_reused" => 0, "sandbox_ca_total_ms" => 157} =
             by_step["ca_exec"]

    assert %{"sandbox_ca_lock_wait_ms" => 3, "sandbox_ca_trust_ms" => 88} = by_step["ca_exec"]

    # Every phase was cross-checked and agreed, so these are the timings a
    # query selecting trustworthy CA clocks keeps.
    assert %{
             "sandbox_ca_clock_checked" => 1,
             "sandbox_ca_timing_suspect" => 0,
             "sandbox_ca_clock_skew_max_ms" => 5
           } = by_step["ca_exec"]

    # The relay half of the same boundary, which is not CA work at all, and
    # the readiness poll that #2906 could only estimate.
    assert %{"relay_warm" => 0, "relay_polls" => 3, "sandbox_relay_ready_ms" => 151} =
             by_step["relay_exec"]

    assert %{
             "sandbox_relay_total_ms" => 166,
             "sandbox_relay_boot_ms" => 38,
             "sandbox_relay_timing_suspect" => 0
           } = by_step["relay_exec"]

    # The relay's clock is monotonic itself; the CA's checked signal is not
    # borrowed for it.
    refute Map.has_key?(by_step["relay_exec"], "sandbox_ca_clock_checked")

    # The two writes report their payload rather than a clock: these are the
    # sizes that decide whether a payload could be inlined into an exec.
    assert by_step["ca_write"].ca_pem_bytes == byte_size("PEM")
    assert by_step["relay_write"].relay_script_bytes > 1_000

    # `ca_pem` is pure host CPU — the span's duration is the whole
    # measurement, and it passes its result through untouched so the
    # caller's error path is the one it always had.
    assert Map.keys(by_step["ca_pem"]) |> Enum.sort() ==
             [:provider, :step, :telemetry_span_context]

    # Sandbox-measured durations are never reported without the label, and
    # the host spans never borrow one.
    assert Enum.all?(Map.keys(by_step["broker_ca_install"]), fn key ->
             not String.starts_with?(to_string(key), "sandbox_")
           end)
  end

  test "a host span, not a sandbox clock, is what each child measures", %{user: user} do
    conv = insert_conversation(user_id: user.id)
    succeeding_sandbox()

    assert :ok = install_under_parent(conv.id)

    # The sandbox said 157 ms; the host span is the host's own monotonic
    # measurement of the same exec and owes nothing to it. Pinning them as
    # independent is the point — #2908 is open precisely because the two
    # clocks were being compared as if they were one.
    assert {"ca_exec", metadata, %{duration: duration}} =
             Enum.find(steps(), &(elem(&1, 0) == "ca_exec"))

    assert metadata["sandbox_ca_total_ms"] == 157
    assert System.convert_time_unit(duration, :native, :millisecond) < 157
  end

  test "a retried CA write is visible as attempts, not only as a longer span", %{user: user} do
    conv = insert_conversation(user_id: user.id)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
        {:error, {:unavailable, :timeout}}
      else
        :ok
      end
    end)

    stub(Managoat.Sandbox.Sprites, :exec, fn
      _h, "bash", _args, _opts -> {:ok, @ca_output, 0}
      _h, "flock", _args, _opts -> {:ok, @relay_output, 0}
    end)

    assert :ok = install_under_parent(conv.id)
    by_step = Map.new(steps(), fn {step, metadata, _} -> {step, metadata} end)

    # The only retried call in the step, and the shape #2906 named as the
    # most likely cause of the 1.598 s Claude/Sprites outlier without being
    # able to confirm it. Now it is an attribute rather than a hypothesis.
    assert by_step["ca_write"].ca_write_attempts == 2
    assert by_step["ca_write"].outcome == :ok
  end

  test "a first-attempt write reports one attempt, so the normal case is not ambiguous", %{
    user: user
  } do
    conv = insert_conversation(user_id: user.id)
    succeeding_sandbox()

    assert :ok = install_under_parent(conv.id)
    by_step = Map.new(steps(), fn {step, metadata, _} -> {step, metadata} end)
    assert by_step["ca_write"].ca_write_attempts == 1
  end

  test "a failed install marks only the phase that failed, and keeps its reason", %{user: user} do
    conv = insert_conversation(user_id: user.id)
    stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)

    stub(Managoat.Sandbox.Sprites, :exec, fn _h, "bash", _args, _opts ->
      {:ok, @ca_output <> "update-ca-certificates: bundle write failed\n", 3}
    end)

    assert {:error, {:broker, :ca_install_exit, 3, reason}} = install_under_parent(conv.id)

    # The phase clocks are stripped from the quoted reason: the markers are
    # ~250 bytes of a 500-byte slice, and the diagnosis must not be the
    # thing the instrumentation evicted.
    assert reason == "update-ca-certificates: bundle write failed\n"
    refute reason =~ "__MANAGOAT_BROKER__"

    # The relay never ran, so four spans: the three CA children and the
    # parent. The failure is attributed to `ca_exec` and to the parent, and
    # the phases the sandbox did complete are still reported.
    attributed =
      for _ <- 1..4 do
        assert_receive {:step, metadata, _}, 5_000
        {metadata.step, Map.get(metadata, :outcome)}
      end

    assert attributed == [
             {"ca_pem", nil},
             {"ca_write", :ok},
             {"ca_exec", :failed},
             {"broker_ca_install", :failed}
           ]
  end

  test "a failed install still carries its clocks and their signals", %{user: user} do
    conv = insert_conversation(user_id: user.id)
    stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)

    # A rebuild that failed after the clock stepped: the install's own exit
    # status is the verdict, and the implausible phase is evidence beside it.
    stub(Managoat.Sandbox.Sprites, :exec, fn _h, "bash", _args, _opts ->
      {:ok,
       """
       __MANAGOAT_BROKER__ ca_lock_wait 1 -
       __MANAGOAT_BROKER__ ca_verify 30 30
       __MANAGOAT_BROKER__ ca_reused 0
       __MANAGOAT_BROKER__ ca_rebuild 1
       __MANAGOAT_BROKER__ ca_trust -880 20
       __MANAGOAT_BROKER__ ca_total -830 60
       update-ca-certificates: bundle write failed
       """, 3}
    end)

    assert {:error, {:broker, :ca_install_exit, 3, reason}} = install_under_parent(conv.id)
    assert reason == "update-ca-certificates: bundle write failed\n"

    assert {"ca_exec", ca_exec, _} =
             Enum.find(steps_until("broker_ca_install"), &(elem(&1, 0) == "ca_exec"))

    assert %{
             :outcome => :failed,
             "ca_rebuild" => 1,
             "sandbox_ca_trust_ms" => -880,
             "sandbox_ca_total_ms" => -830,
             "sandbox_ca_clock_skew_max_ms" => 900,
             "sandbox_ca_timing_suspect" => 1,
             # The lock wait had no monotonic reading; the later checked
             # phases cannot make the record look fully checked.
             "sandbox_ca_clock_checked" => 0
           } = ca_exec
  end

  test "suspect or unchecked clocks never fail a successful install", %{user: user} do
    conv = insert_conversation(user_id: user.id)
    stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)

    stub(Managoat.Sandbox.Sprites, :exec, fn
      _h, "bash", _args, _opts -> {:ok, "__MANAGOAT_BROKER__ ca_total - -\n", 0}
      _h, "flock", _args, _opts -> {:ok, "__MANAGOAT_BROKER__ relay_total x\n", 0}
    end)

    assert :ok = install_under_parent(conv.id)
    by_step = Map.new(steps(), fn {step, metadata, _} -> {step, metadata} end)

    assert %{:outcome => :ok, "sandbox_ca_timing_suspect" => 1, "sandbox_ca_clock_checked" => 0} =
             by_step["ca_exec"]

    refute Map.has_key?(by_step["ca_exec"], "sandbox_ca_total_ms")
    assert %{:outcome => :ok, "sandbox_relay_timing_suspect" => 1} = by_step["relay_exec"]
  end

  test "a relay that never becomes ready is attributed to the relay, not the CA", %{user: user} do
    conv = insert_conversation(user_id: user.id)
    stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)

    stub(Managoat.Sandbox.Sprites, :exec, fn
      _h, "bash", _args, _opts ->
        {:ok, @ca_output, 0}

      _h, "flock", _args, _opts ->
        # `relay_total` is reported on every path, including the readiness
        # timeout, so a failed ensure still accounts for its host span.
        {:ok, "__MANAGOAT_BROKER__ relay_probe 4\n__MANAGOAT_BROKER__ relay_total 20045\n", 1}
    end)

    assert {:error, {:broker, :relay_unavailable}} = install_under_parent(conv.id)
    by_step = Map.new(steps(), fn {step, metadata, _} -> {step, metadata} end)

    assert by_step["ca_exec"].outcome == :ok
    assert by_step["relay_exec"].outcome == :failed
    assert by_step["relay_exec"]["sandbox_relay_total_ms"] == 20_045
    refute Map.has_key?(by_step["relay_exec"], "sandbox_relay_ready_ms")
  end

  test "the step names stay a bounded set, so the histogram's cardinality does", %{user: user} do
    conv = insert_conversation(user_id: user.id)
    succeeding_sandbox()

    assert :ok = install_under_parent(conv.id)

    # `fountain.provision_step` is tagged by `step` (#537). Every name the
    # split adds is a literal in the source; none carries a conversation,
    # sandbox, path or provider-assigned identifier.
    for {step, metadata, _} <- steps() do
      assert step in ~w(ca_pem ca_write ca_exec relay_write relay_exec broker_ca_install)
      refute step =~ conv.id
      refute Map.has_key?(metadata, :staging)
    end
  end
end
