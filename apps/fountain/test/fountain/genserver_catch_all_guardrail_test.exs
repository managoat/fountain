defmodule Fountain.GenServerCatchAllGuardrailTest do
  @moduledoc """
  Every `handle_info/2` and `handle_cast/2` in core ends in a catch-all (#2380).

  `use GenServer` supplies a `handle_info/2` that logs an unmatched message and
  continues, and a `handle_cast/2` that stops with `{:bad_cast, message}`.
  **Defining a clause of your own removes the generated one**, so from that
  commit on every message the module does not match raises
  `FunctionClauseError` and takes the process down — a monitor it never asked
  for, an `:EXIT` from a linked task, a telemetry or PubSub message, a caller
  on a later release sending a shape this node does not know yet.

  Nothing makes that visible. It is not a compiler warning, it is not at the
  call site, and it does not show in a diff that adds a second clause to a
  module whose first clause was fine. #2377 shipped the hole in
  `Fountain.Machines.Machine`, and the sweep that found it found two more, in
  modules that had carried it for months. Hence a standing check rather than
  three fixes.

  ## What counts as a catch-all

  A final clause whose first argument is an unbound variable and which carries
  no guard — `def handle_info(message, state)`, not
  `def handle_info(msg, state) when is_reference(msg)` and not
  `def handle_info({:DOWN, ref, _, _, _}, state)`. The clause is expected to
  log the message's *shape* and return `{:noreply, state}`; what it logs is a
  matter for review, that it exists is this file's business.

  ## What is exempt

  LiveViews, by the `use FountainWeb, :live_view` in their source. A LiveView
  process crashing is a reconnect: the client re-mounts and the user sees a
  flicker, where a supervised singleton crashing drops whatever it was holding
  and spends the supervisor's restart budget.

  Anything else goes in `@exemptions` with a reason, so the next hole has to be
  argued for rather than merely added. An entry that names a file which has
  since grown a catch-all fails too — a stale exemption is how a list like this
  stops meaning anything.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)

  @sources @lib
           |> Path.join("**/*.ex")
           |> Path.wildcard()
           |> Enum.sort()

  @callbacks [:handle_info, :handle_cast]

  # `%{"relative/path.ex" => reason}`. Empty on purpose: every module in core
  # that defines one of these callbacks ends it in a catch-all today.
  @exemptions %{}

  test "sources were found" do
    # A wrong @lib would make every test below pass over an empty list.
    assert length(@sources) > 100
  end

  test "every module defining handle_info/2 or handle_cast/2 ends it in a catch-all" do
    offenders =
      for path <- @sources,
          relative = Path.relative_to(path, @lib),
          not exempt?(path, relative),
          {callback, line} <- holes(path),
          do: "#{relative}:#{line}: #{callback}/2 has no final catch-all clause"

    assert offenders == [],
           """
           A GenServer callback with no catch-all takes its process down on any
           message it does not match, because defining a clause removes the one
           `use GenServer` generates (#2380).

           Add a final clause with an unbound first argument and no guard, which
           logs the message's shape — never its payload — and returns
           `{:noreply, state}`. If the process genuinely should die instead, add
           the file to `@exemptions` with the reason.

           #{Enum.join(offenders, "\n")}
           """
  end

  test "no exemption is stale" do
    stale =
      for {relative, _reason} <- @exemptions do
        path = Path.join(@lib, relative)

        cond do
          not File.exists?(path) -> "#{relative}: no such file"
          holes(path) == [] -> "#{relative}: has a catch-all now; drop the exemption"
          true -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    assert stale == [], Enum.join(stale, "\n")
  end

  test "an exemption carries a reason" do
    for {relative, reason} <- @exemptions do
      assert is_binary(reason) and String.length(reason) > 20,
             "#{relative}: an exemption needs a reason somebody can argue with"
    end
  end

  # ── the walk ──────────────────────────────────────────────────────────────

  # A LiveView is recognised by its `use`, not by living under `live/`: the
  # directory is a convention and the `use` is what makes the crash a reconnect.
  defp exempt?(path, relative) do
    Map.has_key?(@exemptions, relative) or File.read!(path) =~ "use FountainWeb, :live_view"
  end

  # `{callback, line_of_the_last_clause}` for each callback in each module of
  # the file whose last clause is not a catch-all.
  defp holes(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    for body <- module_bodies(ast),
        callback <- @callbacks,
        clauses = clauses(body, callback),
        clauses != [],
        {line, first_arg, guard?} = List.last(clauses),
        guard? or not unbound?(first_arg),
        do: {callback, line}
  end

  defp module_bodies(ast) do
    {_ast, bodies} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_name, [do: body]]} = node, acc -> {node, [body | acc]}
        node, acc -> {node, acc}
      end)

    bodies
  end

  # Clauses of `callback` defined directly in this module body, in source
  # order. Nested `defmodule`s are pruned rather than descended into, so their
  # clauses are attributed to them and not to their parent.
  defp clauses(body, callback) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {:defmodule, _meta, _args}, acc ->
          {nil, acc}

        {:def, meta, [head | _]} = node, acc ->
          case clause(head, callback) do
            nil -> {node, acc}
            {first_arg, guard?} -> {node, [{meta[:line], first_arg, guard?} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp clause({:when, _meta, [head, _guard]}, callback) do
    with {first_arg, false} <- clause(head, callback), do: {first_arg, true}
  end

  defp clause({callback, _meta, [first_arg, _state]}, callback), do: {first_arg, false}
  defp clause(_head, _callback), do: nil

  # `message` and `_message` are unbound; `%{} = state`, `{:DOWN, _, _, _, _}`
  # and `:tick` are not. A var is `{atom, meta, context}` with an atom context,
  # which is what separates it from a zero-argument call.
  defp unbound?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp unbound?(_other), do: false
end
