defmodule Fountain.ChatGPTFixtures do
  @moduledoc """
  What a ChatGPT sign-in looks like from the outside (ADR 0047), for tests:
  unsigned JWTs with the claims codex reads, the `auth.json` a laptop's
  `codex login` writes, and Req.Test stubs for `auth.openai.com`.

  Nothing here is signed. Codex never checks a signature either, so an
  unsigned token is exactly as good as a real one to every reader in this
  code base.
  """

  alias Fountain.PlatformChatGPT
  alias Fountain.PlatformChatGPT.OAuth

  @auth_claim "https://api.openai.com/auth"

  @doc "A three-segment unsigned JWT carrying `claims`."
  def jwt(claims) when is_map(claims) do
    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    header <> "." <> payload <> ".sig"
  end

  @doc "An access token expiring `seconds` from now, with the `iat`/`exp` codex reads."
  def access_token(seconds \\ 3_600, extra \\ %{}) do
    now = System.os_time(:second)
    jwt(Map.merge(%{"iat" => now, "exp" => now + seconds, "sub" => "user_1"}, extra))
  end

  @doc "An id_token with the three auth claims and an email."
  def id_token(overrides \\ %{}) do
    jwt(%{
      "email" => Map.get(overrides, :email, "admin@example.com"),
      @auth_claim => %{
        "chatgpt_account_id" => Map.get(overrides, :account_id, "acct_platform_1"),
        "chatgpt_user_id" => Map.get(overrides, :user_id, "user_1"),
        "chatgpt_plan_type" => Map.get(overrides, :plan_type, "pro")
      }
    })
  end

  @doc "The `auth.json` `codex login` writes for a ChatGPT sign-in."
  def auth_json(opts \\ %{}) do
    Jason.encode!(%{
      "auth_mode" => Map.get(opts, :auth_mode, "chatgpt"),
      "tokens" => %{
        "id_token" => Map.get(opts, :id_token, id_token(opts)),
        "access_token" => Map.get(opts, :access_token, access_token()),
        "refresh_token" => Map.get(opts, :refresh_token, "rt_original"),
        "account_id" => Map.get(opts, :account_id, "acct_platform_1")
      },
      "last_refresh" => "2026-09-08T00:00:00Z"
    })
  end

  @doc "Connect the platform grant from a pasted file; returns the account."
  def connect!(opts \\ %{}) do
    {:ok, account} =
      PlatformChatGPT.connect_from_auth_json(auth_json(opts),
        actor_user_id: Map.get(opts, :actor_user_id)
      )

    account
  end

  @doc "A directly inserted user fixture; application linking remains unbuilt."
  def user_grant!(user_id, opts \\ %{}) do
    alias Fountain.ChatGPTAccounts.Cipher
    alias Fountain.PlatformChatGPT.{Account, Tokens}

    access = Map.get(opts, :access_token, access_token(60))
    account_id = Map.get(opts, :account_id, "acct-user")

    {:ok, encrypted} =
      Cipher.encrypt_user_tokens(user_id, %{
        access_token: access,
        refresh_token: Map.get(opts, :refresh_token, "rt_user")
      })

    attrs =
      Map.merge(encrypted, %{
        kind: "chatgpt",
        account_id: account_id,
        plan_type: "pro",
        id_claims: %{"account_id" => account_id, "user_id" => "user_1", "plan_type" => "pro"},
        access_expires_at: Tokens.expires_at(access),
        last_refreshed_at:
          Map.get(opts, :last_refreshed_at, DateTime.utc_now() |> DateTime.truncate(:second))
      })

    %Account{user_id: user_id}
    |> Account.connect_changeset(attrs)
    |> Fountain.Repo.insert!()
  end

  @doc """
  Stub `auth.openai.com`. `handlers` maps a request path to a function of
  the decoded JSON body returning `{status, body}`; a path with no handler
  fails the test, so a call nobody expected is visible.
  """
  def stub_auth(handlers) when is_map(handlers) do
    # The refresh runs in `Fountain.PlatformChatGPT.Refresher`, a process of
    # its own, so the stub must be visible beyond the test's `$callers`
    # chain. Shared mode does that; every test file using this is
    # `async: false` for the one platform row anyway.
    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(OAuth, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)

      case Map.fetch(handlers, conn.request_path) do
        {:ok, handler} ->
          {status, response} = handler.(body)
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)

        :error ->
          raise "unexpected call to #{conn.request_path} with #{inspect(Map.keys(body))}"
      end
    end)
  end

  @doc "A refresh that rotates: the old refresh token is accepted once and the new tokens come back."
  def stub_refresh(opts \\ %{}) do
    stub_auth(%{
      "/oauth/token" => fn body ->
        expected = Map.get(opts, :expect_refresh, "rt_original")

        if body["grant_type"] == "refresh_token" and body["refresh_token"] == expected do
          {200,
           %{
             "access_token" => Map.get(opts, :access_token, access_token(7_200, %{"n" => 2})),
             "refresh_token" => Map.get(opts, :refresh_token, "rt_rotated"),
             "id_token" => Map.get(opts, :id_token, id_token())
           }}
        else
          {400, %{"error" => "refresh_token_reused"}}
        end
      end
    })
  end

  @doc "A refresh the server refuses with a terminal code."
  def stub_refusal(code \\ "refresh_token_reused") do
    stub_auth(%{"/oauth/token" => fn _ -> {400, %{"error" => %{"code" => code}}} end})
  end
end
