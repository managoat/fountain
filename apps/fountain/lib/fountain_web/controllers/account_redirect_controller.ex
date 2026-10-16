defmodule FountainWeb.AccountRedirectController do
  @moduledoc "Stable account URLs redirect to the configured static OAuth app."
  use FountainWeb, :controller

  @sections ~w(api-keys oauth-apps connections password delete inference-credentials bindings)

  def index(conn, params) do
    section = if params["open"] in @sections, do: params["open"], else: ""
    redirect(conn, external: Fountain.Apps.account_url(section))
  end

  def section(%{assigns: %{account_section: section}} = conn, _params)
      when section in @sections do
    redirect(conn, external: Fountain.Apps.account_url(section))
  end
end
