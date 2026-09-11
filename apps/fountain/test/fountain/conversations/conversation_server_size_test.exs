defmodule Fountain.Conversations.ConversationServerSizeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  `ConversationServer` only shrinks.

  Tracker #1369 refactors the server by subtraction: each sub-issue moves a
  function family into a module under `Fountain.Conversations.*` and lowers
  `@pin` to the file's new length in the same PR. The pin is the file's line
  count on `main` at the last move, so a change that makes the file longer
  fails here and has to say why.

  The shape is the docs-style allowlist that only shrinks (#911): the number
  is not a target, it is a record of where the file is, and the only edit it
  accepts is downward. Lower it when you move something out; never raise it.
  """

  @pin 2759

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
