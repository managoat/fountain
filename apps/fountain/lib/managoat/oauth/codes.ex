defmodule Managoat.OAuth.Codes do
  @moduledoc """
  The authorization-code half of the grant state machine: issue a code on
  consent, exchange it once for an API key. Codes live five minutes, are
  stored hashed, and are bound to the subject, the client, the redirect URI
  and the PKCE challenge the exchange must answer.

  This module trusts its caller to have validated the request:
  `Fountain.OAuth.authorize/3` runs `Fountain.OAuth.validate_request/2` (the
  client, the development-mode boundary, the redirect and the PKCE challenge)
  before calling `authorize/4`. What a token is, and the audit trail, are
  `Fountain.OAuth.Host`'s.
  """

  import Ecto.Query, warn: false

  alias Fountain.OAuth.Host
  alias Fountain.Repo
  alias Managoat.OAuth.AuthorizationCode

  @code_ttl_seconds 300
  @token_ttl_seconds 30 * 24 * 3600

  @doc "Seconds a token minted by `exchange/2` lives."
  @spec token_ttl_seconds() :: pos_integer()
  def token_ttl_seconds, do: @token_ttl_seconds

  @doc """
  The subject consented to a validated request from `client_id`: issue a
  code. Returns `{:ok, raw_code}`; the raw code goes to the redirect and is
  never stored, only its hash is. Audits `:authorized` through the host.
  """
  @spec authorize(binary(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def authorize(subject, client_id, params, opts \\ [])
      when is_binary(subject) and is_binary(client_id) do
    raw = random_token()

    %AuthorizationCode{}
    |> AuthorizationCode.changeset(%{
      code_hash: hash(raw),
      subject_id: subject,
      client_id: client_id,
      redirect_uri: params["redirect_uri"],
      code_challenge: params["code_challenge"],
      expires_at: now_s() |> DateTime.add(@code_ttl_seconds, :second)
    })
    |> Repo.insert()
    |> case do
      {:ok, _code} ->
        _ =
          Host.audit(
            :authorized,
            %{subject_id: subject, client_id: client_id, redirect_uri: params["redirect_uri"]},
            opts
          )

        {:ok, raw}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Exchange a code for a token. `params` is the token request: `code`,
  `code_verifier`, `client_id`, `redirect_uri`. Returns
  `{:ok, %{access_token: token, expires_in: seconds, api_key: key}}`,
  `{:error, :invalid_grant}` for every way a grant can be wrong (unknown,
  used, expired, wrong client, wrong redirect, wrong verifier), or
  `{:error, :server_error}` when the key could not be minted.

  The code is marked used **before** the host mints, on purpose: a code is
  proof of one consent, and a mint that fails answers `:server_error` with
  the code consumed rather than leaving a live code behind.
  """
  @spec exchange(map(), keyword()) ::
          {:ok, %{access_token: String.t(), expires_in: pos_integer(), api_key: term()}}
          | {:error, :invalid_grant | :server_error}
  def exchange(params, opts \\ []) when is_map(params) do
    now = now_s()

    with code when is_binary(code) <- params["code"] || {:error, :invalid_grant},
         verifier when is_binary(verifier) <- params["code_verifier"] || {:error, :invalid_grant},
         %AuthorizationCode{} = row <-
           Repo.get_by(AuthorizationCode, code_hash: hash(code)) || {:error, :invalid_grant},
         true <- row.client_id == params["client_id"] || {:error, :invalid_grant},
         true <- row.redirect_uri == params["redirect_uri"] || {:error, :invalid_grant},
         true <- DateTime.compare(row.expires_at, now) == :gt || {:error, :invalid_grant},
         true <- pkce_verify(verifier, row.code_challenge) || {:error, :invalid_grant},
         {1, _} <- mark_used(row.id, now) do
      expires_at = DateTime.add(now, @token_ttl_seconds, :second)

      grant = %{
        type: :authorization_code,
        id: row.id,
        client_id: row.client_id,
        expires_at: expires_at
      }

      case Host.issue_token(row.subject_id, grant, opts) do
        {:ok, %{access_token: access_token, token: token}} ->
          {:ok, %{access_token: access_token, expires_in: @token_ttl_seconds, api_key: token}}

        {:error, _} ->
          {:error, :server_error}
      end
    else
      {0, _} -> {:error, :invalid_grant}
      {:error, _} = err -> err
      _ -> {:error, :invalid_grant}
    end
  end

  # Single use is the conditional update: two concurrent exchanges of one
  # code cannot both see {1, _}.
  defp mark_used(id, now) do
    from(c in AuthorizationCode, where: c.id == ^id and is_nil(c.used_at))
    |> Repo.update_all(set: [used_at: now])
  end

  @doc "S256: base64url(sha256(verifier)) == challenge, constant-time."
  @spec pkce_verify(term(), term()) :: boolean()
  def pkce_verify(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    computed = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    byte_size(computed) == byte_size(challenge) and :crypto.hash_equals(computed, challenge)
  end

  def pkce_verify(_, _), do: false

  @doc false
  @spec random_token() :: String.t()
  def random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc false
  @spec hash(binary()) :: String.t()
  def hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  @doc false
  @spec now_s() :: DateTime.t()
  def now_s, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
