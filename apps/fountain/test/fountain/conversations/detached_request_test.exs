defmodule Fountain.Conversations.DetachedRequestTest do
  @moduledoc """
  A permission request that outlived its turn (#1635), from the row it lives
  on to the turn its answer opens.

  The `ConversationServer` half — the `waiting` stop reason, the deadline the
  ask decides and the `session/prompt` the resume turn writes — is in
  `conversation_server_acp_test.exs`, where a real peer is driven. What is
  here is what happens with no peer at all, which is the state a detached
  request spends its life in.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, DetachedRequest}
  alias Fountain.Workers.DetachedRequestSweeper

  @options [
    %{"optionId" => "allow", "kind" => "allow_once", "name" => "Apply"},
    %{"optionId" => "deny", "kind" => "reject_once", "name" => "Stop"}
  ]

  defp waiting_conversation(opts \\ []) do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")

    # Parked, which is where a conversation with a detached request spends
    # its wait (0017): the answer has to wake it.
    sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite", status: "suspended")

    conv =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    request = %{
      "request_id" => Keyword.get(opts, :request_id, "7.abc"),
      "tool" => "Bash",
      "options" => @options,
      "asked_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "detached_timeout_ms" => 86_400_000
    }

    turn = insert_turn(conv, %{prompt: "apply the plan", status: "completed"})

    {:ok, turn} =
      Conversations._unsafe_update_turn(turn, %{
        waiting: true,
        pending_permission: request,
        permission_deadline: Keyword.get(opts, :deadline, hours_from_now(24))
      })

    %{user: user, conv: conv, sandbox: sandbox, turn: turn, request: request}
  end

  defp hours_from_now(hours) do
    DateTime.utc_now() |> DateTime.add(hours * 3600, :second) |> DateTime.truncate(:second)
  end

  # The wake path starts a server through Horde. Only the prompt it is handed
  # matters here, so record it and start nothing.
  defp record_wake do
    test = self()

    stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)

    stub(ConversationServer, :queue_initial_prompt, fn _pid, prompt, _images ->
      send(test, {:resume_prompt, prompt})
      :ok
    end)

    stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
      {:ok, %{status: :suspended, raw: %{name: "test-sprite"}}}
    end)

    stub(Managoat.Sandbox.Sprites, :resume, fn handle -> {:ok, handle} end)
  end

  describe "the wire shape of the resume prompt" do
    test "is one line of JSON under the key a _meta field would use" do
      request = %{"request_id" => "7.abc", "tool" => "Bash"}
      prompt = DetachedRequest.resume_prompt(request, "answered", "allow")

      refute String.contains?(prompt, "\n")

      assert %{"fountain/permission_answer" => answer} = Jason.decode!(prompt)
      assert answer["request_id"] == "7.abc"
      assert answer["tool"] == "Bash"
      assert answer["outcome"] == "answered"
      assert answer["option_id"] == "allow"
      assert {:ok, _, _} = DateTime.from_iso8601(answer["answered_at"])
    end

    test "an expiry carries the outcome and the option the agent itself offered" do
      request = %{"request_id" => "7.abc", "tool" => "Bash", "options" => @options}
      option_id = DetachedRequest.deny_option_id(request)
      assert option_id == "deny"

      assert %{"fountain/permission_answer" => %{"outcome" => "timeout", "option_id" => "deny"}} =
               request
               |> DetachedRequest.resume_prompt("timeout", option_id)
               |> Jason.decode!()
    end

    test "an agent that offered no rejection gets a null option, never an invented one" do
      request = %{
        "request_id" => "7.abc",
        "options" => [%{"optionId" => "yes", "kind" => "allow_once"}]
      }

      assert DetachedRequest.deny_option_id(request) == nil
    end
  end

  describe "the deadline" do
    test "the shorter of the request and the policy wins, either way round" do
      # The request is written inside the sandbox and the policy is the
      # tenant's, so an agent may bound its own wait and may not extend one.
      long = %{"_meta" => %{"fountain" => %{"timeout" => 172_800}}}
      short = %{"_meta" => %{"fountain" => %{"timeout" => 60}}}

      assert DetachedRequest.timeout_ms(long, 600) == 600_000
      assert DetachedRequest.timeout_ms(short, 600) == 60_000
    end

    test "the request alone is honoured, past the policy's absence" do
      params = %{"_meta" => %{"fountain" => %{"timeout" => 172_800}}}
      assert DetachedRequest.timeout_ms(params, nil) == 172_800_000
    end

    test "the policy is used when the request names none" do
      assert DetachedRequest.timeout_ms(%{}, 600) == 600_000
      assert DetachedRequest.timeout_ms(nil, 600) == 600_000
    end

    test "with neither, the global ask timeout stands" do
      assert DetachedRequest.timeout_ms(nil, nil) ==
               Fountain.Conversations.Lifecycle.ask_timeout_ms()
    end

    test "a timeout that is not a positive number of seconds falls through" do
      for value <- [0, -5, "soon", "60s", nil] do
        params = %{"_meta" => %{"fountain" => %{"timeout" => value}}}
        assert DetachedRequest.timeout_ms(params, 600) == 600_000
      end
    end

    test "the sandbox cannot name a deadline no timestamp can hold" do
      # This half has no door to be refused at: the request is already
      # raised. Unbounded, 1e15 seconds produced a year-31690765 deadline
      # that Postgrex refused to encode, raising inside the `handle_info`
      # that detaches the request and leaving the turn `running` with the
      # request neither detached nor denied. It falls back instead, which is
      # what every other unreadable value here does.
      over = Fountain.PermissionPolicy.max_ask_timeout_seconds() + 1

      for value <- [over, 999_999_999_999_999] do
        params = %{"_meta" => %{"fountain" => %{"timeout" => value}}}

        assert DetachedRequest.timeout_ms(params, 600) == 600_000

        assert DetachedRequest.timeout_ms(params, nil) ==
                 Fountain.Conversations.Lifecycle.ask_timeout_ms()
      end
    end

    test "the ceiling itself is honoured, so the bound is not an off-by-one" do
      max = Fountain.PermissionPolicy.max_ask_timeout_seconds()
      params = %{"_meta" => %{"fountain" => %{"timeout" => max}}}

      assert DetachedRequest.timeout_ms(params, nil) == max * 1000

      # And the deadline it produces is a datetime Postgres can store.
      assert DetachedRequest.deadline(max * 1000).year < 294_276
    end

    test "a deadline longer than the idle bound is accepted, which is the point" do
      # The in-turn ceiling has to sit under the idle bound because the turn
      # holding it defers idle reclaim. A detached request holds nothing open,
      # so nothing here clamps it.
      params = %{"_meta" => %{"fountain" => %{"timeout" => 2 * 24 * 3600}}}
      idle_ms = Fountain.Conversations.Lifecycle.idle_timeout_seconds() * 1000

      assert DetachedRequest.timeout_ms(params, nil) > idle_ms
    end
  end

  describe "listing what a conversation waits on" do
    test "GET-shaped data for every request that outlived a turn" do
      %{conv: conv, turn: turn} = waiting_conversation()

      assert [request] = Conversations._unsafe_list_pending_requests(conv.id)
      assert request.request_id == "7.abc"
      assert request.tool == "Bash"
      assert Enum.map(request.options, & &1["optionId"]) == ["allow", "deny"]
      assert request.turn_id == turn.id
      assert request.deadline
    end

    test "a turn that ended without one is not listed" do
      %{conv: conv, turn: turn} = waiting_conversation()

      {:ok, _} =
        Conversations._unsafe_update_turn(turn, %{waiting: false, pending_permission: nil})

      assert Conversations._unsafe_list_pending_requests(conv.id) == []
    end
  end

  describe "answering" do
    test "resolves the row, says done on the stream and opens the resume turn" do
      %{user: user, conv: conv, turn: turn} = waiting_conversation()
      record_wake()

      assert :ok =
               Conversations.answer_permission_request(conv.id, user.id, "7.abc", "allow",
                 actor: "api"
               )

      reloaded = Repo.reload(turn)
      refute reloaded.waiting
      refute reloaded.pending_permission
      refute reloaded.permission_deadline

      assert [event] = request_stages(conv.id, "done")
      assert event["outcome"] == "answered"
      assert event["option_id"] == "allow"

      assert_receive {:resume_prompt, prompt}

      assert %{"fountain/permission_answer" => %{"request_id" => "7.abc", "option_id" => "allow"}} =
               Jason.decode!(prompt)
    end

    test "the audit row carries the answerer, exactly as an in-turn answer does" do
      %{user: user, conv: conv} = waiting_conversation()
      record_wake()

      assert :ok =
               Conversations.answer_permission_request(conv.id, user.id, "7.abc", "allow",
                 actor: "api",
                 request_ip: "203.0.113.9"
               )

      assert answered =
               user.id
               |> Audit.list_recent_for_user(50)
               |> Enum.find(&(&1.action == "conversation.permission_answered"))

      assert answered.actor == "api"
      assert answered.request_ip == "203.0.113.9"
      assert answered.metadata["request_id"] == "7.abc"
      assert answered.metadata["option_id"] == "allow"
    end

    test "the first answer wins and the second is too late" do
      %{user: user, conv: conv} = waiting_conversation()
      record_wake()

      assert :ok = Conversations.answer_permission_request(conv.id, user.id, "7.abc", "allow")

      # Every "too late" is one 409 at the door, so which of the two reasons
      # comes back is not a distinction a client can act on.
      assert {:error, reason} =
               Conversations.answer_permission_request(conv.id, user.id, "7.abc", "allow")

      assert reason in [:no_pending_permission, :not_running]
    end

    test "an option the agent never offered is refused rather than relayed" do
      # The fail-closed rule the peer applies in turn, applied here where no
      # peer is left to apply it.
      %{user: user, conv: conv, turn: turn} = waiting_conversation()

      assert {:error, :unknown_option} =
               Conversations.answer_permission_request(conv.id, user.id, "7.abc", "made-up")

      assert Repo.reload(turn).waiting
    end

    test "a sprite may not answer its own prompt, detached or not" do
      %{user: user, conv: conv, turn: turn} = waiting_conversation()

      assert {:error, :sprite_may_not_answer} =
               Conversations.answer_permission_request(conv.id, user.id, "7.abc", "allow",
                 actor: "sprite"
               )

      assert Repo.reload(turn).waiting
    end

    test "another tenant gets not_found rather than a hint" do
      %{conv: conv} = waiting_conversation()
      other = insert_verified_user()

      assert {:error, :not_found} =
               Conversations.answer_permission_request(conv.id, other.id, "7.abc", "allow")
    end

    test "a turn already running refuses the answer before the row is touched" do
      # The resume turn cannot queue behind one, so refusing beats resolving
      # the request into a prompt nobody delivers.
      %{user: user, conv: conv, turn: turn} = waiting_conversation()
      {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

      assert {:error, :busy} =
               Conversations.answer_permission_request(conv.id, user.id, "7.abc", "allow")

      assert Repo.reload(turn).waiting
    end

    test "a spent balance refuses the answer, and the request survives to be answered again" do
      # The wake would refuse this anyway; running the gate first is what keeps
      # the answer from being resolved into a prompt nobody delivers, and the
      # caller from being told somebody else answered.
      %{user: user, conv: conv, turn: turn} = waiting_conversation()
      drain_credit(user)

      assert {:error, :insufficient_credits} =
               Conversations.answer_permission_request(conv.id, user.id, "7.abc", "allow")

      assert Repo.reload(turn).waiting
      refute Repo.reload(turn).pending_permission == nil

      # Topped up, the same answer lands.
      {:ok, _} = Fountain.Credits.grant(user.id, 500, "grant_admin", idempotency_key: "topup")
      record_wake()

      assert :ok = Conversations.answer_permission_request(conv.id, user.id, "7.abc", "allow")
      refute Repo.reload(turn).waiting
    end

    test "a delivery that fails after the row is resolved says so in its own words" do
      # The gates passed and something took the conversation in between. The
      # answer is gone, so the caller must not be told to retry it, and must
      # not be told somebody else answered either.
      %{user: user, conv: conv, turn: turn} = waiting_conversation()

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, :busy}
      end)

      assert {:error, :answer_not_delivered} =
               Conversations.answer_permission_request(conv.id, user.id, "7.abc", "allow")

      refute Repo.reload(turn).waiting
    end

    test "a terminated conversation cannot carry an answer, so the request is left alone" do
      %{user: user, conv: conv, turn: turn} = waiting_conversation()
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})

      assert {:error, :not_running} =
               Conversations.answer_permission_request(conv.id, user.id, "7.abc", "allow")

      assert Repo.reload(turn).waiting
    end
  end

  describe "the sweep" do
    test "denies a request past its deadline and tells the agent" do
      %{conv: conv, turn: turn} = waiting_conversation(deadline: hours_from_now(-1))
      record_wake()

      assert DetachedRequestSweeper.sweep_expired_requests() == 1

      reloaded = Repo.reload(turn)
      refute reloaded.waiting
      refute reloaded.pending_permission

      assert [event] = request_stages(conv.id, "done")
      assert event["outcome"] == "timeout"
      # Chosen from the agent's own list, never invented.
      assert event["option_id"] == "deny"

      assert_receive {:resume_prompt, prompt}

      assert %{"fountain/permission_answer" => %{"outcome" => "timeout", "option_id" => "deny"}} =
               Jason.decode!(prompt)
    end

    test "the denial is audited to the sweep, because no human decided it" do
      %{user: user} = waiting_conversation(deadline: hours_from_now(-1))
      record_wake()

      assert DetachedRequestSweeper.sweep_expired_requests() == 1

      assert denied =
               user.id
               |> Audit.list_recent_for_user(50)
               |> Enum.find(&(&1.action == "conversation.permission_denied"))

      assert denied.actor == "system:detached_request_sweeper"
      assert denied.metadata["tool"] == "Bash"
      assert denied.metadata["verdict"] == "timeout"
    end

    test "a running turn leaves the request for the next sweep" do
      # The denial is owed, but the turn that carries it cannot queue behind a
      # turn already in flight. Resolving anyway would lose it with nothing to
      # retry from.
      %{conv: conv, turn: turn} = waiting_conversation(deadline: hours_from_now(-1))
      {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})
      reject(&ConversationServer.send_prompt/4)

      assert DetachedRequestSweeper.sweep_expired_requests() == 0

      reloaded = Repo.reload(turn)
      assert reloaded.waiting
      assert reloaded.pending_permission["request_id"] == "7.abc"
      assert request_stages(conv.id, "done") == []
    end

    test "a spent balance leaves the request for the next sweep" do
      %{user: user, conv: conv, turn: turn} = waiting_conversation(deadline: hours_from_now(-1))
      drain_credit(user)

      # No `reject/1` here: the second half of this test needs the delivery to
      # work. The untouched row and the silent stream are what say the first
      # sweep delivered nothing.
      assert DetachedRequestSweeper.sweep_expired_requests() == 0
      assert Repo.reload(turn).waiting
      assert request_stages(conv.id, "done") == []

      # And it is not lost: the next sweep, after a top-up, carries it.
      {:ok, _} = Fountain.Credits.grant(user.id, 500, "grant_admin", idempotency_key: "topup")
      record_wake()

      assert DetachedRequestSweeper.sweep_expired_requests() == 1
      refute Repo.reload(turn).waiting
    end

    test "a conversation that is over resolves the request without a resume turn" do
      # No turn will ever carry the denial, so the card stops waiting rather
      # than the sweep finding the same row every minute forever.
      %{conv: conv, turn: turn} = waiting_conversation(deadline: hours_from_now(-1))
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
      reject(&ConversationServer.send_prompt/4)

      assert DetachedRequestSweeper.sweep_expired_requests() == 1

      refute Repo.reload(turn).waiting
      assert [%{"outcome" => "timeout"}] = request_stages(conv.id, "done")
      assert DetachedRequestSweeper.sweep_expired_requests() == 0
    end

    test "a request still inside its deadline is left alone" do
      %{turn: turn} = waiting_conversation(deadline: hours_from_now(24))

      assert DetachedRequestSweeper.sweep_expired_requests() == 0
      assert Repo.reload(turn).waiting
    end

    test "a turn that is not waiting is never a candidate, whatever its deadline" do
      # A request held inside a running turn is the process timer's, and this
      # sweep must not reach into one.
      %{turn: turn} = waiting_conversation(deadline: hours_from_now(-1))

      {:ok, _} =
        Repo.update(Ecto.Changeset.change(turn, waiting: false, status: "running"))

      assert DetachedRequestSweeper.sweep_expired_requests() == 0
    end

    test "the worker runs the sweep" do
      %{turn: turn} = waiting_conversation(deadline: hours_from_now(-1))
      record_wake()

      assert :ok = DetachedRequestSweeper.perform(%Oban.Job{args: %{}})
      refute Repo.reload(turn).waiting
    end
  end

  describe "the row-level resolution" do
    test "a second resolution of the same request finds nothing to update" do
      %{turn: turn} = waiting_conversation()

      assert :ok = Conversations._unsafe_resolve_detached_request(turn, "answered", "allow")

      assert {:error, :no_pending_permission} =
               Conversations._unsafe_resolve_detached_request(turn, "timeout", "deny")
    end

    test "the stage event marks the resolution as a detached one" do
      %{conv: conv, turn: turn} = waiting_conversation()

      assert :ok = Conversations._unsafe_resolve_detached_request(turn, "answered", "allow")
      assert [event] = request_stages(conv.id, "done")
      assert event["detached"] == true
    end
  end

  # `insert_verified_user/1` holds the $5 opening credit (ADR 0031), so
  # refusal has to be arranged rather than assumed. Exactly the balance, so a
  # later grant puts the account back above zero rather than into a hole no
  # top-up in a test would fill.
  defp drain_credit(user) do
    balance = Repo.reload!(user).credit_balance_cents

    if balance > 0 do
      {:ok, _} =
        Fountain.Credits.debit(user.id, balance, "burn_turn", idempotency_key: "drain-#{user.id}")
    end

    :ok
  end

  defp request_stages(conv_id, state) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.kind == "stage" and &1.stage == "request" and &1.state == state))
    |> Enum.map(&Jason.decode!(&1.data))
  end
end
