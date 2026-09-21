defmodule Fountain.ChatGPTLinkAttemptsTest do
  # ADR 0060 stage 4: beginning, reading and cancelling a device-code
  # sign-in. `async: false`: the broker's config, the rollout flag and the
  # grant ceiling are application state.
  use Fountain.DataCase, async: false

  import Fountain.BrokerTestHelpers
  import Fountain.ChatGPTFixtures

  alias Fountain.Audit.Event
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.{AttemptView, LinkAttempt}
  alias Fountain.PlatformChatGPT.Account

  setup do
    enable_chatgpt_subscriptions()
    %{user: insert_verified_user(), other: insert_verified_user()}
  end

  defp start(user, target, opts \\ []) do
    ChatGPTAccounts.start_attempt_for_user(
      user.id,
      target,
      Keyword.put_new(opts, :device_start, device_start(self()))
    )
  end

  defp link!(user, name, account_id) do
    {:ok, grant} = ChatGPTAccounts.connect_for_user(user.id, name, user_tokens(account_id))
    grant
  end

  defp events(user) do
    Repo.all(
      from(e in Event,
        where: e.user_id == ^user.id and like(e.action, "chatgpt_link_attempt.%"),
        order_by: [asc: e.inserted_at, asc: e.id]
      )
    )
  end

  defp overdue!(attempt_id) do
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(a in LinkAttempt, where: a.id == ^attempt_id), set: [expires_at: past])
  end

  describe "starting a link" do
    test "answers with the code to type, stores it encrypted and leaves an event without it",
         %{user: user} do
      assert {:ok, %AttemptView{} = view} = start(user, %{name: "  Work "})
      assert_received {:device_start, code}

      assert %AttemptView{
               kind: :link,
               name: "Work",
               grant_id: nil,
               state: "pending",
               user_code: ^code,
               verification_url: "https://auth.openai.com/codex/device",
               poll_interval: 5,
               result_grant_id: nil,
               failure: nil
             } = view

      assert DateTime.diff(view.expires_at, DateTime.utc_now(), :second) in 880..900

      row = Repo.get!(LinkAttempt, view.id)
      assert row.user_id == user.id
      assert is_binary(row.user_code_ciphertext) and is_binary(row.device_auth_ciphertext)
      refute row.user_code_ciphertext =~ code

      assert [%Event{} = event] = events(user)

      assert %{
               action: "chatgpt_link_attempt.started",
               resource_type: "chatgpt_link_attempt",
               actor: "self",
               metadata: %{"kind" => "link", "name" => "Work"}
             } = event

      assert event.resource_id == view.id
      refute inspect(event) =~ code
      refute inspect(event) =~ "deviceauth_"

      # It links nothing by itself.
      assert ChatGPTAccounts.list_for_user(user.id) == []
      assert {:ok, ^view} = ChatGPTAccounts.get_attempt_for_user(view.id, user.id)
      assert [^view] = ChatGPTAccounts.list_pending_attempts_for_user(user.id)
    end

    test "the code does not print from the view", %{user: user} do
      assert {:ok, view} = start(user, %{name: "Work"})
      assert is_binary(view.user_code)
      refute inspect(view) =~ view.user_code
      refute inspect(view) =~ "user_code"
    end

    test "carries the caller's attribution", %{user: user} do
      assert {:ok, _} = start(user, %{name: "Work"}, actor: "api", request_ip: "203.0.113.9")
      assert [%{actor: "api", request_ip: "203.0.113.9"}] = events(user)
    end

    test "a name that is blank, too long, a grant's or an open attempt's is a changeset, " <>
           "and the auth server is not asked",
         %{user: user} do
      link!(user, "Work", "acct-work")
      assert {:ok, _} = start(user, %{name: "Personal"})
      assert_received {:device_start, _}

      for {name, message} <- [
            {"   ", "can't be blank"},
            {String.duplicate("n", 201), "should be at most 200 character(s)"},
            {"Work", "already names a ChatGPT subscription on this account"},
            {" Personal ", "already names a ChatGPT subscription on this account"}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} = start(user, %{name: name})
        assert %{name: [^message]} = errors_on(changeset)
      end

      refute_received {:device_start, _}
      assert [_only] = events(user)
    end

    test "neither a name nor a grant is refused", %{user: user} do
      assert {:error, :invalid_target} = start(user, %{})
      refute_received {:device_start, _}
    end

    @tag :capture_log
    test "an auth server that gives no code leaves nothing behind", %{user: user} do
      failing = fn -> {:error, {:device_start, 503, nil}} end

      assert {:error, :auth_unreachable} = start(user, %{name: "Work"}, device_start: failing)
      assert Repo.aggregate(LinkAttempt, :count) == 0
      assert events(user) == []
    end
  end

  describe "who may start one" do
    for attrs <- [
          %{principal: true},
          %{email_verified_at: nil},
          %{suspended_at: ~U[2026-09-01 00:00:00Z]}
        ] do
      test "an owner with #{inspect(attrs)} cannot, and can still read and cancel", %{user: user} do
        grant = link!(user, "Work", "acct-work")
        assert {:ok, open} = start(user, %{name: "Personal"})
        assert_received {:device_start, _}

        user |> change(unquote(Macro.escape(attrs))) |> Repo.update!()

        assert {:error, :ineligible_owner} = start(user, %{name: "Side"})
        assert {:error, :ineligible_owner} = start(user, %{grant_id: grant.grant_id})
        refute_received {:device_start, _}

        assert {:ok, %{state: "pending"}} = ChatGPTAccounts.get_attempt_for_user(open.id, user.id)

        assert {:ok, %{state: "cancelled"}} =
                 ChatGPTAccounts.cancel_attempt_for_user(open.id, user.id)
      end
    end

    test "an owner id that is not one is refused, not raised" do
      assert {:error, :ineligible_owner} = start(%{id: "not-a-uuid"}, %{name: "Work"})
      assert ChatGPTAccounts.list_pending_attempts_for_user("not-a-uuid") == []
    end
  end

  describe "ownership" do
    test "another account's attempt cannot be read, listed or cancelled",
         %{user: user, other: other} do
      assert {:ok, mine} = start(user, %{name: "Work"})
      before = Repo.get!(LinkAttempt, mine.id)

      assert {:error, :not_found} = ChatGPTAccounts.get_attempt_for_user(mine.id, other.id)
      assert {:error, :not_found} = ChatGPTAccounts.cancel_attempt_for_user(mine.id, other.id)
      assert ChatGPTAccounts.list_pending_attempts_for_user(other.id) == []

      assert Repo.get!(LinkAttempt, mine.id) == before
      assert events(other) == []
      assert [%{action: "chatgpt_link_attempt.started"}] = events(user)
    end

    test "another account's grant cannot be reconnected, and the auth server is not asked",
         %{user: user, other: other} do
      theirs = link!(other, "Work", "acct-work")

      assert {:error, :not_found} = start(user, %{grant_id: theirs.grant_id})
      assert {:error, :not_found} = start(user, %{grant_id: Ecto.UUID.generate()})
      assert {:error, :not_found} = start(user, %{grant_id: "not-a-uuid"})
      refute_received {:device_start, _}
      assert Repo.aggregate(LinkAttempt, :count) == 0
    end

    test "ids that are not ids name nothing", %{user: user} do
      assert {:error, :not_found} = ChatGPTAccounts.get_attempt_for_user("nope", user.id)
      assert {:error, :not_found} = ChatGPTAccounts.cancel_attempt_for_user("nope", user.id)

      assert {:error, :not_found} =
               ChatGPTAccounts.get_attempt_for_user(Ecto.UUID.generate(), "nope")
    end
  end

  describe "the pending limit" do
    test "a fourth open sign-in is refused across all of the account's grants, " <>
           "and a cancelled one frees its place",
         %{user: user, other: other} do
      grant = link!(user, "Work", "acct-work")

      assert {:ok, first} = start(user, %{name: "Personal"})
      assert {:ok, _} = start(user, %{name: "Side"})
      assert {:ok, _} = start(user, %{grant_id: grant.grant_id})
      for _ <- 1..3, do: assert_received({:device_start, _})

      assert {:error, {:link_attempts_exceeded, %{count: 3, limit: 3}}} =
               start(user, %{name: "Fourth"})

      refute_received {:device_start, _}
      assert Repo.aggregate(from(a in LinkAttempt, where: a.user_id == ^user.id), :count) == 3

      # The limit is per account.
      assert {:ok, _} = start(other, %{name: "Work"})

      assert {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(first.id, user.id)
      assert {:ok, _} = start(user, %{name: "Fourth"})
    end

    test "an attempt that ran out of time does not count", %{user: user} do
      attempts = for n <- 1..3, do: start(user, %{name: "Grant #{n}"}) |> elem(1)
      overdue!(hd(attempts).id)

      assert {:ok, _} = start(user, %{name: "Fourth"})
    end
  end

  describe "the hourly limit" do
    defp churn(user, target, times) do
      for _ <- 1..times do
        assert {:ok, attempt} = start(user, target)
        assert_received {:device_start, _}
        assert {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(attempt.id, user.id)
      end
    end

    test "starting and cancelling is refused at the eleventh, and the auth server is not asked",
         %{user: user, other: other} do
      churn(user, %{name: "Work"}, 10)

      assert {:error, {:link_attempts_rate_limited, %{limit: 10, retry_after: seconds}}} =
               start(user, %{name: "Work"})

      assert seconds in 1..3600
      refute_received {:device_start, _}
      assert Repo.aggregate(LinkAttempt, :count) == 10
      assert length(events(user)) == 20

      # An account's count is its own.
      assert {:ok, _} = start(other, %{name: "Work"})
    end

    test "a reconnect counts, and is refused like a link", %{user: user} do
      grant = link!(user, "Work", "acct-work")
      churn(user, %{grant_id: grant.grant_id}, 10)

      assert {:error, {:link_attempts_rate_limited, _}} = start(user, %{grant_id: grant.grant_id})
      assert {:error, {:link_attempts_rate_limited, _}} = start(user, %{name: "Personal"})
      refute_received {:device_start, _}
    end

    test "a start more than an hour old no longer counts", %{user: user} do
      churn(user, %{name: "Work"}, 10)

      [oldest | _] =
        Repo.all(from(a in LinkAttempt, order_by: [asc: a.inserted_at], select: a.id))

      long_ago = DateTime.utc_now() |> DateTime.add(-3601, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(a in LinkAttempt, where: a.id == ^oldest),
        set: [inserted_at: long_ago]
      )

      assert {:ok, _} = start(user, %{name: "Work"})
    end
  end

  describe "the ceiling" do
    setup do
      previous = Application.fetch_env!(:fountain, :chatgpt_grant_ceiling)
      Application.put_env(:fountain, :chatgpt_grant_ceiling, 1)
      on_exit(fn -> Application.put_env(:fountain, :chatgpt_grant_ceiling, previous) end)
    end

    test "a full account is refused a new link at once, and may still reconnect",
         %{user: user} do
      grant = link!(user, "Work", "acct-work")

      assert {:error, {:grant_limit_reached, %{count: 1, limit: 1}}} =
               start(user, %{name: "Personal"})

      refute_received {:device_start, _}
      assert Repo.aggregate(LinkAttempt, :count) == 0

      assert {:ok, %{kind: :reconnect}} = start(user, %{grant_id: grant.grant_id})
    end
  end

  describe "a reconnect" do
    test "pins the grant's generation on the row and shows neither it nor the grant's name " <>
           "as the attempt's",
         %{user: user} do
      grant = link!(user, "Work", "acct-work")

      assert {:ok, view} = start(user, %{grant_id: grant.grant_id})
      assert %AttemptView{kind: :reconnect, name: nil, state: "pending"} = view
      assert view.grant_id == grant.grant_id
      refute Map.has_key?(view, :expected_generation)

      row = Repo.get!(LinkAttempt, view.id)
      assert row.expected_generation == grant.generation
      assert row.grant_id == grant.grant_id

      assert [%{metadata: metadata}] = events(user)
      assert metadata == %{"kind" => "reconnect", "grant_id" => grant.grant_id, "name" => "Work"}

      # Nothing about the grant moved: the old credential serves until the new one commits.
      assert {:ok, ^grant} = ChatGPTAccounts.get_for_user(grant.grant_id, user.id)
    end

    test "one open sign-in per grant: the second is told which one is open", %{user: user} do
      work = link!(user, "Work", "acct-work")
      personal = link!(user, "Personal", "acct-personal")

      assert {:ok, first} = start(user, %{grant_id: work.grant_id})
      assert_received {:device_start, _}

      assert {:error, {:link_attempt_pending, %{attempt_id: open}}} =
               start(user, %{grant_id: work.grant_id})

      assert open == first.id
      refute_received {:device_start, _}

      # Another grant of the same account is not in the way.
      assert {:ok, _} = start(user, %{grant_id: personal.grant_id})

      assert {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(first.id, user.id)
      assert {:ok, _} = start(user, %{grant_id: work.grant_id})
    end

    test "an open sign-in that ran out of time is not in the way, and is written expired",
         %{user: user} do
      grant = link!(user, "Work", "acct-work")
      assert {:ok, first} = start(user, %{grant_id: grant.grant_id})
      overdue!(first.id)

      assert {:ok, second} = start(user, %{grant_id: grant.grant_id})
      assert second.id != first.id

      assert %LinkAttempt{state: "expired", user_code_ciphertext: nil} =
               Repo.get!(LinkAttempt, first.id)

      assert [
               %{action: "chatgpt_link_attempt.started"},
               %{action: "chatgpt_link_attempt.expired", actor: "system:chatgpt_link_attempt"},
               %{action: "chatgpt_link_attempt.started"}
             ] = events(user)
    end

    test "the clock is read again once the auth server has answered", %{user: user} do
      grant = link!(user, "Work", "acct-work")
      assert {:ok, first} = start(user, %{name: "Side"})
      answer = device_start(self())

      # The auth server takes its time, and the open sign-in runs out meanwhile.
      slow = fn ->
        overdue!(first.id)
        Process.sleep(2_100)
        answer.()
      end

      asked_at = DateTime.utc_now()
      assert {:ok, second} = start(user, %{grant_id: grant.grant_id}, device_start: slow)

      assert %LinkAttempt{state: "expired"} = Repo.get!(LinkAttempt, first.id)
      assert DateTime.diff(second.expires_at, asked_at, :second) > 900
    end

    test "a disconnected grant may be reconnected", %{user: user} do
      grant = link!(user, "Work", "acct-work")
      assert :ok = ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id)
      {:ok, tombstone} = ChatGPTAccounts.get_for_user(grant.grant_id, user.id)

      assert {:ok, view} = start(user, %{grant_id: grant.grant_id})
      assert Repo.get!(LinkAttempt, view.id).expected_generation == tombstone.generation
    end
  end

  describe "cancelling" do
    test "ends the attempt, drops its secrets, and is recorded once however often it is asked",
         %{user: user} do
      assert {:ok, view} = start(user, %{name: "Work"})

      assert {:ok, %AttemptView{state: "cancelled", user_code: nil, verification_url: nil}} =
               ChatGPTAccounts.cancel_attempt_for_user(view.id, user.id, actor: "ui")

      assert %LinkAttempt{
               state: "cancelled",
               user_code_ciphertext: nil,
               device_auth_ciphertext: nil
             } = Repo.get!(LinkAttempt, view.id)

      assert {:ok, %{state: "cancelled"}} =
               ChatGPTAccounts.cancel_attempt_for_user(view.id, user.id)

      assert {:ok, %{state: "cancelled", user_code: nil}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)

      assert ChatGPTAccounts.list_pending_attempts_for_user(user.id) == []

      assert [
               %{action: "chatgpt_link_attempt.started"},
               %{
                 action: "chatgpt_link_attempt.cancelled",
                 actor: "ui",
                 metadata: %{"kind" => "link", "name" => "Work"}
               }
             ] = events(user)
    end
  end

  describe "expiry" do
    test "a pending attempt past its time reads expired and shows no code before anything " <>
           "writes that",
         %{user: user} do
      assert {:ok, view} = start(user, %{name: "Work"})
      overdue!(view.id)

      assert %LinkAttempt{state: "pending"} = Repo.get!(LinkAttempt, view.id)

      assert {:ok, %AttemptView{state: "expired", user_code: nil, verification_url: nil}} =
               ChatGPTAccounts.get_attempt_for_user(view.id, user.id)

      assert ChatGPTAccounts.list_pending_attempts_for_user(user.id) == []
    end

    test "cancelling an expired attempt says so, and writes what happened", %{user: user} do
      assert {:ok, view} = start(user, %{name: "Work"})
      overdue!(view.id)

      assert {:error, {:link_attempt_not_pending, %{state: "expired"}}} =
               ChatGPTAccounts.cancel_attempt_for_user(view.id, user.id)

      assert %LinkAttempt{state: "expired", user_code_ciphertext: nil} =
               Repo.get!(LinkAttempt, view.id)

      assert [_, %{action: "chatgpt_link_attempt.expired"}] = events(user)

      # And again: still not pending, and nothing more is recorded.
      assert {:error, {:link_attempt_not_pending, %{state: "expired"}}} =
               ChatGPTAccounts.cancel_attempt_for_user(view.id, user.id)

      assert [_, _] = events(user)
    end
  end

  describe "with linking turned off" do
    test "a new link is refused and the auth server is not asked; what exists stays operable",
         %{user: user} do
      grant = link!(user, "Work", "acct-work")
      assert {:ok, open} = start(user, %{name: "Personal"})
      assert_received {:device_start, _}

      chatgpt_subscriptions_flag(false)
      refute ChatGPTAccounts.linking_enabled_for?(user.id)

      assert {:error, :subscriptions_not_enabled} = start(user, %{name: "Side"})
      refute_received {:device_start, _}

      # Reconnect, read, list, cancel, rename, disconnect and remove do not ask the flag.
      assert {:ok, reconnect} = start(user, %{grant_id: grant.grant_id})
      assert {:ok, _} = ChatGPTAccounts.get_attempt_for_user(open.id, user.id)
      assert [_, _] = ChatGPTAccounts.list_pending_attempts_for_user(user.id)
      assert {:ok, _} = ChatGPTAccounts.cancel_attempt_for_user(reconnect.id, user.id)
      assert [%{name: "Work"}] = ChatGPTAccounts.list_for_user(user.id)
      assert {:ok, _} = ChatGPTAccounts.rename_for_user(grant.grant_id, user.id, "Old job")
      assert :ok = ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id)
      assert :ok = ChatGPTAccounts.remove_for_user(grant.grant_id, user.id)
      assert Repo.aggregate(from(a in Account, where: a.user_id == ^user.id), :count) == 0
    end

    test "the flag is off for an account nobody turned it on for", %{user: user} do
      Application.put_env(:fountain, :feature_flag_overrides, %{})

      refute ChatGPTAccounts.linking_enabled_for?(user.id)
      assert {:error, :subscriptions_not_enabled} = start(user, %{name: "Work"})
    end

    test "a deployment with no broker links nothing and reconnects nothing", %{user: user} do
      grant = link!(user, "Work", "acct-work")
      disable_broker()

      refute ChatGPTAccounts.linking_enabled_for?(user.id)
      assert {:error, :subscriptions_not_enabled} = start(user, %{name: "Personal"})
      assert {:error, :subscriptions_not_enabled} = start(user, %{grant_id: grant.grant_id})
      refute_received {:device_start, _}

      # The kill switch does not need one.
      assert :ok = ChatGPTAccounts.disconnect_for_user(grant.grant_id, user.id)
    end
  end
end
