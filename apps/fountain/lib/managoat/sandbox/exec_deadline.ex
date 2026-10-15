defmodule Managoat.Sandbox.ExecDeadline do
  @moduledoc false

  # This bounds local collection, not provider execution or synchronous startup.
  # Keep the original timeout for the public error even as the budget decreases.
  def new(:infinity), do: {:infinity, :infinity}
  def new(timeout), do: {timeout, System.monotonic_time(:millisecond) + timeout}

  def remaining({:infinity, :infinity}), do: :infinity
  def remaining({_timeout, deadline}), do: max(deadline - System.monotonic_time(:millisecond), 0)

  def check(deadline) do
    if remaining(deadline) == 0, do: error(deadline), else: :ok
  end

  def error({timeout, _deadline}), do: {:error, {:unavailable, {:exec_timeout, timeout}}}
end
