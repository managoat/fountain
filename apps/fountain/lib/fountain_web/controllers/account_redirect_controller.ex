defmodule FountainWeb.AccountRedirectController do
  @moduledoc "Legacy account URLs select the matching built-in settings section."
  use FountainWeb, :controller

  @sections ~w(api-keys oauth-apps connections password delete inference-credentials bindings security)

  def index(conn, params) do
    section = if params["open"] in @sections, do: params["open"], else: ""
    redirect(conn, to: Fountain.Apps.account_url(section))
  end

  def section(%{assigns: %{account_section: section}} = conn, _params)
      when section in @sections do
    redirect(conn, to: Fountain.Apps.account_url(section))
  end
end
