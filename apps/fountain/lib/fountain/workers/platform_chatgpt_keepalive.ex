defmodule Fountain.Workers.PlatformChatGPTKeepalive do
  @moduledoc """
  Keeps the deployment's ChatGPT grant alive while nobody runs codex
  (ADR 0047 decision 3).

  Codex itself refreshes a ChatGPT login when `last_refresh` is older than
  eight days, which is the auth server's idle window as far as the code
  shows. Fountain is the only holder of the refresh token, so if no codex
  conversation runs for a week the grant would lapse with nothing to renew
  it. This daily job renews any grant unrefreshed for
  `ChatGPTAccounts.platform_keepalive_days/0` (six), one refresh at most.

  A grant the server refuses is marked `revoked` by the context with the
  reason code; this job only reports it.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case Fountain.ChatGPTAccounts.platform_keepalive() do
      {:ok, :refreshed} ->
        Logger.info("platform chatgpt: keepalive refreshed the grant")
        :ok

      {:ok, :skipped} ->
        :ok

      {:error, reason} ->
        # The shape only: the reason may be a struct holding a URL or a body.
        Logger.warning(
          "platform chatgpt: keepalive could not refresh: " <>
            Fountain.ChatGPTAccounts.failure_shape(reason)
        )

        :ok
    end
  end
end
