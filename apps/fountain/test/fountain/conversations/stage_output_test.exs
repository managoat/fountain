defmodule Fountain.Conversations.StageOutputTest do
  # Not async: the budget test sets the application-wide byte budget.
  use Fountain.DataCase, async: false

  alias Fountain.Conversations
  alias Fountain.Conversations.Output
  alias Fountain.Conversations.StageOutput

  defp rows(conv_id) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "output",
        order_by: e.id
      )
    )
  end

  defp feed_all(conv_id, chunks) do
    chunks
    |> Enum.reduce(StageOutput.new(conv_id, "setup"), &StageOutput.feed(&2, &1))
    |> StageOutput.finish()
  end

  test "writes whole lines as they complete, and the unfinished one at the end" do
    conv = insert_conversation()
    feed_all(conv.id, ["a\nb", "c\nd\ne", "", "f"])

    assert Enum.map(rows(conv.id), &{&1.data, &1.stage, &1.stream, &1.turn_id}) == [
             {"a\n", "setup", "stdout", nil},
             {"bc\nd\n", "setup", "stdout", nil},
             {"ef", "setup", "stdout", nil}
           ]
  end

  test "a line longer than max_pending is written without waiting for its end" do
    conv = insert_conversation()
    long = String.duplicate("x", StageOutput.max_pending())
    s = StageOutput.new(conv.id, "setup") |> StageOutput.feed(long)

    assert [%{data: ^long}] = rows(conv.id)
    assert s.pending == ""
  end

  test "keeps the last 2 kB for an error to quote" do
    conv = insert_conversation()
    s = feed_all(conv.id, [String.duplicate("a", 3_000), "\nend\n"])

    assert byte_size(StageOutput.tail(s)) == 2_000
    assert String.ends_with?(StageOutput.tail(s), "a\nend\n")
  end

  test "counts against the conversation's durable budget: the head is kept, then one marker" do
    previous = Application.get_env(:fountain, :log_output_byte_budget)
    Application.put_env(:fountain, :log_output_byte_budget, 10)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :log_output_byte_budget, previous),
        else: Application.delete_env(:fountain, :log_output_byte_budget)
    end)

    conv = insert_conversation()
    feed_all(conv.id, ["12345\n", "67890\n", "more\n", "and more\n"])

    assert [%{data: "12345\n"}, %{data: marker, stream: "stderr", stage: "setup"}] =
             rows(conv.id)

    assert marker == Output.cap_marker(10)
  end
end
