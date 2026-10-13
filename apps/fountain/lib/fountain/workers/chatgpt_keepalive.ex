defmodule Fountain.Workers.ChatGPTKeepalive do
  @moduledoc """
  Daily: refresh every active ChatGPT subscription last refreshed more than
  six days ago (ADR 0070). An access token lives about ten days and a turn
  does not refresh one (`Fountain.ChatGPT`), so this is what keeps an idle
  subscription usable. One at a time; a deployment has a handful.

  A refresh another replica holds is skipped, a transient failure is tried
  again tomorrow (four days before the token lapses), and a terminal one
  marks the subscription revoked inside `Fountain.ChatGPT.refresh/1`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias Fountain.ChatGPT

  @impl Oban.Worker
  def perform(_job) do
    # system sweep: every owner's subscription, by design.
    for sub <- ChatGPT._unsafe_due_for_refresh() do
      case ChatGPT.refresh(sub) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.info("chatgpt keepalive: subscription #{sub.id} not refreshed (#{reason})")
      end
    end

    :ok
  end
end
