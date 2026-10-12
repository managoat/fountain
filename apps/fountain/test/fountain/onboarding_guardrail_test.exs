defmodule Fountain.OnboardingGuardrailTest do
  @moduledoc """
  Every reply materializer must decide onboarding completion at the write (#2055).

  Like AuditGuardrailTest, intentional silence needs a named function and a
  reason. Unlike a fixed inventory, discovery scans production source for
  reply_text maps/keywords and field setters, follows local builder helpers,
  and checks each function that also calls a Repo insert/update operation.
  Private writers count; a call elsewhere in the module does not cover them.

  This checks visible calls, not control flow or data flow: dynamic modules or
  field names, raw SQL and builders in another module need discovery extended
  when introduced.
  OnboardingFirstReplyTest covers the behavior of the live seams.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deliberately_silent %{
    {Fountain.Conversations, :_unsafe_backfill_reply_texts, 0} =>
      "Historical repair for turns predating reply_text does not replay the " <>
        "onboarding stamp per repaired turn; that repair gap remains tracked in #2054."
  }

  test "every discovered reply writer calls activation or has a documented exclusion" do
    functions =
      ["apps/*/lib/**/*.ex", "ee/lib/**/*.ex"]
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
      |> Enum.flat_map(&(File.read!(&1) |> functions()))

    writers = writers(functions)

    assert Enum.map(writers, &elem(&1, 0)) == [
             {Fountain.Conversations, :_unsafe_backfill_reply_texts, 0},
             {Fountain.Conversations, :_unsafe_orphan_turn, 3},
             {Fountain.Conversations, :_unsafe_update_turn, 2},
             {Fountain.Conversations, :end_running_turn, 5}
           ],
           "Reply-writer inventory changed: review discovery and update the inventory explicitly"

    assert violations(writers, @deliberately_silent) == []
  end

  test "a new writer is detected even when a neighboring writer calls activation" do
    source = """
    defmodule Example do
      def covered(turn, text) do
        updated = turn |> Turn.changeset(%{reply_text: text}) |> Repo.update!()
        Fountain.Onboarding.turn_replied(updated)
      end

      def newly_added(turn, text) do
        turn |> Turn.changeset(%{"reply_text" => text}) |> Repo.update!()
      end
    end
    """

    assert source |> functions() |> writers() |> violations(%{}) == [
             {{Example, :newly_added, 2}, :missing_activation}
           ]
  end

  test "private writers and local builders are discovered, including piped setters" do
    source = """
    defmodule Example do
      defp finish(turn, text) do
        turn |> Turn.changeset(reply_attrs(text)) |> Repo.update!()
      end

      defp reply_attrs(text), do: attrs(text)
      defp attrs(text), do: %{} |> Map.put(:reply_text, text)

      def bulk(text), do: Repo.update_all(Turn, set: [reply_text: text])
      def insert(text), do: Repo.insert!(%Turn{reply_text: text})

      def read(turn), do: Repo.one(from t in Turn, select: t.reply_text)
    end
    """

    assert source |> functions() |> writers() |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [
             {Example, :bulk, 1},
             {Example, :finish, 2},
             {Example, :insert, 1}
           ]
  end

  test "function-level exception sections do not hide a writer in the main body" do
    for {section, handler} <- [
          {"rescue", "_error -> :ok"},
          {"catch", ":throw, _reason -> :ok"},
          {"after", ":ok"},
          {"else", "_value -> :ok"}
        ] do
      source = """
      defmodule Example do
        def finish(turn, text) do
          turn |> Turn.changeset(%{reply_text: text}) |> Repo.update!()
        #{section}
          #{handler}
        end
      end
      """

      assert source |> functions() |> writers() |> violations(%{}) == [
               {{Example, :finish, 2}, :missing_activation}
             ],
             "A function-level #{section} hid the main-body reply writer"
    end
  end

  test "reply writes inside function-level exception sections are discovered" do
    for {section, pattern} <- [
          {"rescue", "_error ->"},
          {"catch", ":throw, _reason ->"},
          {"after", ""},
          {"else", "_value ->"}
        ] do
      source = """
      defmodule Example do
        defp finish(turn, text) do
          :ok
        #{section}
          #{pattern} turn |> Turn.changeset(%{reply_text: text}) |> Repo.update!()
        end
      end
      """

      assert source |> functions() |> writers() |> violations(%{}) == [
               {{Example, :finish, 2}, :missing_activation}
             ],
             "The reply writer inside function-level #{section} was skipped"
    end
  end

  test "an instrumented clause does not cover an uninstrumented rescued clause of the same MFA" do
    source = """
    defmodule Example do
      def finish(:live, turn, text) do
        updated = turn |> Turn.changeset(%{reply_text: text}) |> Repo.update!()
        Fountain.Onboarding.turn_replied(updated)
      end

      def finish(:repair, turn, text) do
        turn |> Turn.changeset(%{reply_text: text}) |> Repo.update!()
      rescue
        error -> {:error, error}
      end
    end
    """

    assert source |> functions() |> writers() |> violations(%{}) == [
             {{Example, :finish, 3}, :missing_activation}
           ]
  end

  test "exclusions need a reason, must name a discovered writer, and must still be silent" do
    silent = {{Example, :repair, 0}, false}
    covered = {{Example, :live, 1}, true}
    stale = {Example, :removed, 0}
    reason = "Historical repair has a separate activation replay."

    assert violations([silent], %{elem(silent, 0) => reason}) == []

    assert violations([silent], %{elem(silent, 0) => "  "}) == [
             {elem(silent, 0), :undocumented_exclusion}
           ]

    assert violations([], %{stale => reason}) == [{stale, :stale_exclusion}]

    assert violations([covered], %{elem(covered, 0) => reason}) == [
             {elem(covered, 0), :instrumented_exclusion}
           ]
  end

  defp functions(source) do
    {_ast, functions} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:defmodule, _, [{:__aliases__, _, names}, [do: body]]} = node, acc ->
          module = Module.concat(names)
          {node, module_functions(module, body) ++ acc}

        node, acc ->
          {node, acc}
      end)

    functions
  end

  defp module_functions(module, body) do
    expressions =
      case body do
        {:__block__, _, expressions} -> expressions
        expression -> [expression]
      end

    for {kind, _, [head, sections]} <- expressions,
        kind in [:def, :defp],
        is_list(sections) do
      head =
        case head do
          {:when, _, [head | _]} -> head
          head -> head
        end

      {name, _, args} = head
      # Function-level rescue/catch/else/after are siblings of :do. Keep all
      # executable sections so neither the main body nor a handler is skipped.
      {{module, name, length(args || [])}, sections}
    end
  end

  defp writers(functions) do
    facts =
      Enum.map(functions, fn {mfa, body} ->
        body =
          Macro.prewalk(body, fn
            {:|>, _, [left, right]} -> Macro.pipe(left, right, 0)
            node -> node
          end)

        {mfa,
         %{
           reply: any?(body, &reply_field?/1),
           persists: any?(body, &repo_write?/1),
           activation: any?(body, &activation?/1),
           calls: local_calls(body)
         }}
      end)

    builders = builders(facts, MapSet.new())

    facts
    |> Enum.filter(fn {{module, _, _}, fact} ->
      fact.persists and (fact.reply or calls_builder?(module, fact, builders))
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1).activation)
    |> Enum.map(fn {mfa, calls} -> {mfa, Enum.all?(calls)} end)
    |> Enum.sort()
  end

  defp builders(facts, known) do
    expanded =
      Enum.reduce(facts, known, fn {{module, name, _}, fact}, acc ->
        if not fact.persists and (fact.reply or calls_builder?(module, fact, known)),
          do: MapSet.put(acc, {module, name}),
          else: acc
      end)

    if expanded == known, do: known, else: builders(facts, expanded)
  end

  defp calls_builder?(module, fact, builders),
    do: Enum.any?(fact.calls, &MapSet.member?(builders, {module, &1}))

  defp local_calls(body) do
    {_body, calls} =
      Macro.prewalk(body, [], fn
        {name, _, args} = node, calls when is_atom(name) and is_list(args) ->
          {node, [name | calls]}

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp reply_field?({key, _value}) when key in [:reply_text, "reply_text"], do: true

  defp reply_field?({{:., _, [_module, setter]}, _, [_target, key, _value]})
       when setter in [:put, :put_new, :put_change, :force_change, :update!] and
              key in [:reply_text, "reply_text"],
       do: true

  defp reply_field?(_), do: false

  defp repo_write?({{:., _, [{:__aliases__, _, module}, operation]}, _, _args}),
    do:
      List.last(module) == :Repo and
        operation in [
          :insert,
          :insert!,
          :insert_all,
          :update,
          :update!,
          :update_all,
          :insert_or_update,
          :insert_or_update!
        ]

  defp repo_write?(_), do: false

  defp activation?({{:., _, [{:__aliases__, _, module}, :turn_replied]}, _, [_turn]}),
    do: module in [[:Onboarding], [:Fountain, :Onboarding]]

  defp activation?(_), do: false

  defp any?(body, predicate) do
    {_body, found?} =
      Macro.prewalk(body, false, fn node, found? ->
        {node, found? or predicate.(node)}
      end)

    found?
  end

  defp violations(writers, exclusions) do
    errors =
      Enum.flat_map(writers, fn {mfa, instrumented?} ->
        case {instrumented?, Map.fetch(exclusions, mfa)} do
          {true, :error} ->
            []

          {true, {:ok, _}} ->
            [{mfa, :instrumented_exclusion}]

          {false, :error} ->
            [{mfa, :missing_activation}]

          {false, {:ok, reason}} ->
            if is_binary(reason) and String.length(String.trim(reason)) > 10,
              do: [],
              else: [{mfa, :undocumented_exclusion}]
        end
      end)

    stale = Map.keys(exclusions) -- Enum.map(writers, &elem(&1, 0))
    Enum.sort(errors ++ Enum.map(stale, &{&1, :stale_exclusion}))
  end
end
