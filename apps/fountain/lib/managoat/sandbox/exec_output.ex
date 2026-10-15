defmodule Managoat.Sandbox.ExecOutput do
  @moduledoc false

  # What an adapter's `exec/4` does with each output frame it collects: keep
  # it for the result, or hand it to the caller's `:on_output` sink as it
  # arrives and keep nothing (see "Exec semantics" in `Managoat.Sandbox`).
  # Called in the caller's process, from the adapter's receive loop.

  def new(opts) do
    %{
      acc: [],
      sink: Keyword.get(opts, :on_output),
      stderr: Keyword.get(opts, :stderr_to_stdout, false)
    }
  end

  def add(%{sink: nil} = out, data), do: %{out | acc: [out.acc | data]}

  def add(%{sink: sink} = out, data) do
    sink.(data)
    out
  end

  def result(%{acc: acc}), do: IO.iodata_to_binary(acc)
end
