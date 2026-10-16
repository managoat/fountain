defmodule RemoteBroker.Control do
  @moduledoc "Bounded HTTPS control calls; never retry or follow redirects with credentials."
  def request(action, body) do
    opts = Application.get_env(:remote_broker, :request_options, [])

    Req.post(
      [
        url:
          Application.fetch_env!(:remote_broker, :control_url) <> "/internal/broker/v1/" <> action,
        auth: {:bearer, Application.fetch_env!(:remote_broker, :token)},
        json: body,
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        finch: [pool_timeout: 1_000],
        connect_options: [timeout: 2_000]
      ] ++ opts
    )
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
