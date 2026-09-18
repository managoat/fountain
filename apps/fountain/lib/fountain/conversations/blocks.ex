defmodule Fountain.Conversations.Blocks do
  @moduledoc """
  A log event's `data`, as the structured blocks a client renders — the one
  seam between what the runtime wrote and what a transcript shows.

  Only the `acp` stream produces structured blocks, parsed by
  `Managoat.ACP.Blocks`. Other streams remain available as raw event data;
  historical vendor stdout dialects are no longer supported.

  `:prompt` is the one kind `for_event/1` never returns. A prompt is not
  something a runtime wrote, so there is no event data to parse it out of: it
  is the text that *caused* a turn, read from the turn row and attached to
  that turn's `turn`/`started` stage event by the API's opt-in
  `?blocks=true&prompts=true`. It is here rather than in the web layer so the
  wire enum has one home and a client renders the human's half of a transcript
  with the same vocabulary as the agent's.

  This used to live in the web UI's transcript component. It moved here so the
  API can serve blocks too (`?blocks=true` on `/events` and the streams) and a
  client on another origin never re-parses a vendor dialect — ADR 0014's
  principle applied to the wire, not just to a render path. Since #867 that is
  the only path: the transcript itself is a client.

  ## Block shapes

  Maps with a `:kind` atom; the rest is per kind. `to_json/1` is the wire
  form: `kind` as a string, `error?` as `error`, nothing else renamed.

  | kind | fields |
  |---|---|
  | `:text`, `:thinking` | `body` |
  | `:plan` | `body` (the full ordered list of checklist entries) |
  | `:tool_use` | `id`, `name`, `summary`, `body` (the input) |
  | `:tool_result` | `tool_id`, `body`, `error?` |
  | `:init` | `summary`, `body` |
  | `:result` | `body`, `raw` |
  | `:error` | `body` |
  | `:raw` | `body`, `summary` |
  | `:permission_request` | `request_id`, `name`, `summary`, `options` |
  | `:prompt` | `body` (the prompt that opened the turn) |

  A `tool_result` is paired to its `tool_use` on `tool_id`; that is the
  client's pass (`pair_tool_results` in the LiveView, the same in the SPA),
  because the two arrive as separate events.
  """

  @kinds ~w(text thinking tool_use tool_result init result error raw permission_request plan prompt)

  @doc "Every `kind` a block can have — the wire enum."
  def kinds, do: @kinds

  @doc """
  The structured blocks in an ACP event; other streams produce no blocks.

  Never returns a `:prompt` block — see the moduledoc.
  """
  @spec for_event(map()) :: [map()]
  def for_event(%{stream: "acp", data: data}) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&Managoat.ACP.Blocks.from_line/1)
  end

  def for_event(_), do: []

  @doc """
  The assistant's text across `events` — every `:text` block of each output
  ACP event, joined and trimmed. What a chat bubble shows for a turn's reply, what the roster previews, and what
  `Fountain.Search` indexes (`turns.reply_text`). `""` when there is none.
  """
  @spec assistant_text([map()]) :: String.t()
  def assistant_text(events) do
    events
    |> Enum.filter(&(&1.kind == "output"))
    |> Enum.flat_map(&for_event/1)
    |> Enum.flat_map(fn
      %{kind: :text, body: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
    |> String.trim()
  end

  @doc "The wire form of a block: string `kind`, `error` for `error?`, everything else as is."
  @spec to_json(map()) :: map()
  def to_json(%{kind: kind} = block) do
    block
    |> Map.new(fn
      {:kind, k} -> {"kind", Atom.to_string(k)}
      {:error?, v} -> {"error", v}
      {k, v} -> {Atom.to_string(k), v}
    end)
    |> Map.put("kind", Atom.to_string(kind))
  end
end
