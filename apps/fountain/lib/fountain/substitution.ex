defmodule Fountain.Substitution do
  @moduledoc """
  `${VAR}` substitution over a nested config value.

  Most tools that read a config file take its strings literally and expand
  nothing, so a config that has to carry a secret or a per-deployment value
  is substituted eagerly, before it is written out. The escape exists for
  the rare consumer that does its own expansion and should see the reference
  intact.

      ${VAR}    eager — replaced from `vars`
      $${VAR}   escape — written through as the literal `${VAR}`
      $$        literal `$`

  Identifiers match `[A-Z_][A-Z0-9_]*` (UPPER_SNAKE_CASE), the shape
  environment variable names take.

  `apply/2` walks maps and lists recursively and rewrites string leaves only;
  every other value passes through untouched. Missing keys are collected
  across the whole value and returned together, so a caller sees every typo
  in one attempt rather than one per attempt, and a value with any missing
  key is returned unchanged rather than half-substituted.

  The server uses this at sandbox provision time for an agent's
  `mcp_servers` config (`Fountain.Conversations.McpServers`), and the
  `fountain` CLI carries a Go implementation of the same syntax for
  apply-time substitution (`cli/internal/substitution`). The two are kept
  behaviourally aligned.

  This was the hex package `managoat_substitution` from 2026-09 to 2026-10
  (ADR 0037); Fountain was its only consumer, so it came back.
  """

  @ref ~r/\$\$|\$\{([A-Z_][A-Z0-9_]*)\}/

  @typedoc "The substitution source: variable name to value."
  @type vars :: %{optional(String.t()) => String.t()}

  @doc """
  Substitutes every `${VAR}` in `value` from `vars`.

  Returns `{:ok, substituted}`, or `{:error, {:missing_vars, names}}` with
  the sorted, de-duplicated names of every variable referenced in `value`
  that `vars` does not hold. On error `value` is not partially rewritten.

      iex> Fountain.Substitution.apply("hello ${NAME}", %{"NAME" => "world"})
      {:ok, "hello world"}

      iex> Fountain.Substitution.apply(%{"a" => "${X}", "b" => ["${Y}", 1]}, %{})
      {:error, {:missing_vars, ["X", "Y"]}}

      iex> Fountain.Substitution.apply("$$${AMOUNT}", %{"AMOUNT" => "5"})
      {:ok, "$5"}
  """
  @spec apply(any(), vars()) :: {:ok, any()} | {:error, {:missing_vars, [String.t()]}}
  def apply(value, vars) do
    {result, missing} = walk(value, vars, [])

    case Enum.uniq(missing) do
      [] -> {:ok, result}
      list -> {:error, {:missing_vars, Enum.sort(list)}}
    end
  end

  defp walk(value, vars, missing) when is_binary(value) do
    new_missing = required_vars(value) |> Enum.reject(&Map.has_key?(vars, &1))

    result =
      if new_missing == [] do
        substitute_string(value, vars)
      else
        # Leave the original string alone when keys are missing; the error
        # is surfaced rather than a half-substituted value that would be
        # confusing to debug.
        value
      end

    {result, new_missing ++ missing}
  end

  defp walk(value, vars, missing) when is_map(value) do
    Enum.reduce(value, {%{}, missing}, fn {k, v}, {acc, m} ->
      {new_v, m2} = walk(v, vars, m)
      {Map.put(acc, k, new_v), m2}
    end)
  end

  defp walk(value, vars, missing) when is_list(value) do
    {rev, m} =
      Enum.reduce(value, {[], missing}, fn v, {acc, m} ->
        {new_v, m2} = walk(v, vars, m)
        {[new_v | acc], m2}
      end)

    {Enum.reverse(rev), m}
  end

  defp walk(value, _vars, missing), do: {value, missing}

  defp required_vars(s) do
    Regex.scan(@ref, s)
    |> Enum.reduce([], fn
      ["$$"], acc -> acc
      [_full, var], acc -> [var | acc]
    end)
  end

  defp substitute_string(s, vars) do
    Regex.replace(@ref, s, fn
      "$$", _ -> "$"
      _full, var -> Map.fetch!(vars, var)
    end)
  end
end
