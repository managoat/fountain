defmodule Fountain.Conversations.PromptReceiptTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{PromptReceipt, Wake}

  test "boot reports an accepted launch and queued follow-up without replaying either" do
    for status <- ["pending", "idle"] do
      conv = insert_conversation(status: status)
      meta = PromptReceipt.accept(conv.id, client_request_id: "submission-#{status}")
      receipt = Repo.get!(PromptReceipt, meta[:prompt_receipt_id])
      receipt |> Ecto.Changeset.change(boot_id: "previous-boot") |> Repo.update!()

      PromptReceipt.recover()
      PromptReceipt.recover()

      events = Conversations._unsafe_list_log_events(conv.id)
      assert [event] = Enum.filter(events, &(&1.stage == "wake" and &1.state == "failed"))

      assert %{
               "reason" => "deployment_interrupted",
               "retryable" => true,
               "client_request_id" => request_id
             } = Jason.decode!(event.data)

      assert request_id == "submission-#{status}"
      assert Conversations._unsafe_list_turns(conv.id) == []
      assert Repo.reload!(conv).status == status
      refute Repo.get(PromptReceipt, receipt.id)
    end
  end

  test "a receipt lost long before the deploy is dropped, not reported as an interruption" do
    conv = insert_conversation(status: "idle")
    stale = DateTime.add(DateTime.utc_now(), -(PromptReceipt.ttl_seconds() + 60), :second)

    receipts =
      for inserted_at <- [stale, nil] do
        meta = PromptReceipt.accept(conv.id, client_request_id: "lost-days-ago")

        Repo.get!(PromptReceipt, meta[:prompt_receipt_id])
        |> Ecto.Changeset.change(boot_id: "previous-boot", inserted_at: inserted_at)
        |> Repo.update!()
      end

    PromptReceipt.recover()

    assert Conversations._unsafe_list_log_events(conv.id) == []
    for receipt <- receipts, do: refute(Repo.get(PromptReceipt, receipt.id))
  end

  test "this boot's live queue and another conversation's receipt are untouched" do
    conv = insert_conversation()
    other = insert_conversation()
    meta = PromptReceipt.accept(conv.id, [])
    assert PromptReceipt.accept(conv.id, meta) == meta
    PromptReceipt.resolve(other.id, meta[:prompt_receipt_id])
    PromptReceipt.recover()
    assert Repo.get(PromptReceipt, meta[:prompt_receipt_id])
    assert Conversations._unsafe_list_log_events(conv.id) == []
  end

  test "admission rollback preserves the receipt and commit removes it" do
    sandbox = insert_sandbox(status: "ready")
    conv = insert_conversation(user_id: sandbox.user_id, sandbox: sandbox, status: "idle")
    meta = PromptReceipt.accept(conv.id, [])

    attrs = %{
      conversation_id: conv.id,
      turn_number: 1,
      status: "running",
      prompt_receipt_id: meta[:prompt_receipt_id]
    }

    assert {:error, %Ecto.Changeset{}} =
             Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id)

    assert Repo.get(PromptReceipt, meta[:prompt_receipt_id])

    assert {:ok, _turn} =
             Conversations._unsafe_create_turn_on_sandbox(
               Map.put(attrs, :prompt, "hello"),
               sandbox.id
             )

    refute Repo.get(PromptReceipt, meta[:prompt_receipt_id])
  end

  test "a refusal reports correlation and settles the receipt" do
    conv = insert_conversation()
    meta = PromptReceipt.accept(conv.id, client_request_id: "request-a")
    Wake.report_unrun_prompt(conv.id, :inference_source_changed, meta)
    refute Repo.get(PromptReceipt, meta[:prompt_receipt_id])
    [event] = Conversations._unsafe_list_log_events(conv.id)
    assert %{"client_request_id" => "request-a", "retryable" => false} = Jason.decode!(event.data)
  end
end
