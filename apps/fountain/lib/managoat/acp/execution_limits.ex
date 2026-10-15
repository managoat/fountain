defmodule Managoat.ACP.ExecutionLimits do
  @moduledoc """
  Typed options for a known adapter's execution-limit extension.

  `new(:claude, attrs)` accepts `:max_model_turns` (a positive integer)
  and `:max_estimated_cost_usd` (a positive number). At least one is required.
  They map to Claude Agent SDK `maxTurns` and `maxBudgetUsd`, respectively.
  Other adapters and arbitrary SDK options are refused, not silently ignored.

  These configure the SDK Query process; they are not a durable conversation
  allowance. A recreated process may reset SDK accounting. The host owns
  adapter/version selection, account ceilings, remaining-budget reservations,
  deadlines and reconciliation of uncertain usage. Estimated dollar limits
  can overshoot through work already in flight.
  """

  @enforce_keys [:adapter]
  defstruct [:adapter, :max_model_turns, :max_estimated_cost_usd]

  @type t :: %__MODULE__{
          adapter: :claude,
          max_model_turns: pos_integer() | nil,
          max_estimated_cost_usd: number() | nil
        }
  @max_safe_integer 9_007_199_254_740_991
  @fields [:max_model_turns, :max_estimated_cost_usd]

  @doc "Build a validated limit set without arbitrary adapter metadata."
  @spec new(atom(), map()) :: {:ok, t()} | {:error, atom()}
  def new(:claude, attrs) when is_map(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @fields)) do
      validate(struct!(__MODULE__, Map.put(attrs, :adapter, :claude)))
    else
      {:error, :invalid_execution_limits}
    end
  end

  def new(:claude, _), do: {:error, :invalid_execution_limits}
  def new(_, _), do: {:error, :unsupported_execution_limit_adapter}

  @doc "Validate again at the peer boundary, including manually built structs."
  @spec validate(term()) :: {:ok, t() | nil} | {:error, atom()}
  def validate(nil), do: {:ok, nil}

  def validate(%__MODULE__{adapter: :claude} = limits) do
    requests = limits.max_model_turns
    dollars = limits.max_estimated_cost_usd

    cond do
      is_nil(requests) and is_nil(dollars) ->
        {:error, :empty_execution_limits}

      not is_nil(requests) and not valid_requests?(requests) ->
        {:error, :invalid_max_model_turns}

      not is_nil(dollars) and not valid_dollars?(dollars) ->
        {:error, :invalid_max_estimated_cost_usd}

      true ->
        {:ok, limits}
    end
  end

  def validate(%__MODULE__{}), do: {:error, :unsupported_execution_limit_adapter}
  def validate(_), do: {:error, :invalid_execution_limits}

  @doc "Add only the two allowlisted SDK options to session creation/resumption."
  @spec session_params(map(), t() | nil) :: map()
  def session_params(params, nil), do: params

  def session_params(params, %__MODULE__{} = limits) do
    {:ok, limits} = validate(limits)

    options =
      %{maxTurns: limits.max_model_turns, maxBudgetUsd: limits.max_estimated_cost_usd}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Map.put(params, :_meta, %{claudeCode: %{options: options}})
  end

  defp valid_requests?(value),
    do: is_integer(value) and value > 0 and value <= @max_safe_integer

  defp valid_dollars?(value),
    do: is_number(value) and value > 0 and value <= @max_safe_integer
end
