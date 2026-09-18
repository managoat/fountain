defmodule FountainWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use FountainWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint FountainWeb.Endpoint

      use FountainWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Fountain.Factory
      import FountainWeb.ConnCase
      import Fountain.ServerStart
    end
  end

  setup tags do
    Fountain.DataCase.setup_sandbox(tags)

    # The schema guard (#1427) validates every response this test renders
    # against the schema its operation declares, and files anything that
    # disagrees under this process. Collect it here rather than raising in the
    # telemetry handler, which `:telemetry` would catch and then detach.
    test_pid = self()

    ExUnit.Callbacks.on_exit(fn ->
      case FountainWeb.SchemaGuard.take(test_pid) do
        [] ->
          :ok

        violations ->
          raise "Schema guard: " <> Enum.join(violations, "\n")
      end
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Sets a multi-tenant session for the given user (browser tests)."
  def login_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
    |> Plug.Conn.put_session(:session_version, user.session_version)
  end

  @doc "Sets Bearer API key header for the given raw key (API tests)."
  def authed_with_key(conn, raw_key) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> raw_key)
  end

  @doc """
  POST/PUT helpers that send JSON bodies with the correct content type.
  Necessary because OpenApiSpex.Plug.CastAndValidate rejects requests
  whose content-type isn't application/json. Uses dispatch/5 because
  the post/put helpers in Phoenix.ConnTest are macros (not callable
  from a regular function).
  """
  def post_json(conn, path, payload) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(FountainWeb.Endpoint, :post, path, Jason.encode!(payload))
  end

  def put_json(conn, path, payload) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(FountainWeb.Endpoint, :put, path, Jason.encode!(payload))
  end

  def patch_json(conn, path, payload) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(FountainWeb.Endpoint, :patch, path, Jason.encode!(payload))
  end

  @doc """
  DELETE with a JSON body — account deletion takes a typed confirmation, so
  the body matters on a verb that usually has none.
  """
  def delete_json(conn, path, payload) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(FountainWeb.Endpoint, :delete, path, Jason.encode!(payload))
  end
end
