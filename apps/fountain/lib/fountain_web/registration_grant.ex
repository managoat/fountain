defmodule FountainWeb.RegistrationGrant do
  @moduledoc """
  Carries a signup access code across the GitHub round trip (#2436).

  The code is typed on the sign-up page, but a GitHub account is created in
  the OAuth callback, one redirect chain later, so it has to wait somewhere.
  The session is the only place, and the session is not private to this flow:
  a connected LiveView logs the whole decoded session at debug level, and a
  password sign-in keeps its fields. So the session holds the code encrypted
  with the endpoint's key, not the code, and only for ten minutes.

  Taking it deletes it. The callback takes it on every path, success or not,
  and passes what it finds to `Accounts.upsert_oauth_user/3`, which checks it
  against the code configured now rather than trusting this check.
  """

  import Plug.Conn, only: [put_session: 3, get_session: 2, delete_session: 2]

  @key :registration_access_grant
  @salt "registration access grant"
  @max_age 600

  @doc "Stores `code` for the callback."
  @spec put(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put(conn, code) when is_binary(code) do
    put_session(conn, @key, Phoenix.Token.encrypt(conn, @salt, code))
  end

  @doc """
  Removes the stored code and returns it: `nil` when there was none, it
  expired, or it does not decrypt.
  """
  @spec take(Plug.Conn.t()) :: {Plug.Conn.t(), String.t() | nil}
  def take(conn) do
    code =
      with grant when is_binary(grant) <- get_session(conn, @key),
           {:ok, code} <- Phoenix.Token.decrypt(conn, @salt, grant, max_age: @max_age) do
        code
      else
        _ -> nil
      end

    {delete_session(conn, @key), code}
  end
end
