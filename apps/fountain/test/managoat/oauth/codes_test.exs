defmodule Managoat.OAuth.CodesTest do
  @moduledoc """
  The authorization-code state machine, through `Fountain.OAuth`'s doors:
  every wrong grant is one answer and consumes nothing, a code is single
  use, and a mint that fails leaves the code spent. Carried over from the
  `managoat_oauth` library's suite when it was folded back (ADR 0037).
  """
  use Fountain.DataCase, async: true
  use Mimic

  import Ecto.Query

  alias Fountain.{Accounts, OAuth}
  alias Managoat.OAuth.{AuthorizationCode, Codes}

  @client "test-app"
  @redirect "https://app.test/callback"

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {verifier, Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)}
  end

  defp request(challenge) do
    %{
      "client_id" => @client,
      "redirect_uri" => @redirect,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256"
    }
  end

  defp token_request(code, verifier) do
    %{
      "code" => code,
      "code_verifier" => verifier,
      "client_id" => @client,
      "redirect_uri" => @redirect
    }
  end

  defp code_for(user) do
    {verifier, challenge} = pkce()
    {:ok, code} = OAuth.authorize(user.id, request(challenge))
    {code, verifier}
  end

  test "a code is exchanged once" do
    user = insert_verified_user()
    {code, verifier} = code_for(user)

    assert {:ok, %{access_token: token, api_key: %Accounts.ApiKey{}}} =
             OAuth.exchange(token_request(code, verifier))

    assert is_binary(token)
    assert {:error, :invalid_grant} = OAuth.exchange(token_request(code, verifier))
  end

  test "every wrong grant is one answer, and none of them consumes the code" do
    user = insert_verified_user()
    {code, verifier} = code_for(user)
    base = token_request(code, verifier)

    assert {:error, :invalid_grant} = OAuth.exchange(%{base | "code_verifier" => verifier <> "x"})
    assert {:error, :invalid_grant} = OAuth.exchange(%{base | "client_id" => "other"})

    assert {:error, :invalid_grant} =
             OAuth.exchange(%{base | "redirect_uri" => "http://localhost:5173/"})

    assert {:error, :invalid_grant} = OAuth.exchange(%{base | "code" => "not-a-code"})
    assert {:error, :invalid_grant} = OAuth.exchange(Map.delete(base, "code_verifier"))
    assert {:error, :invalid_grant} = OAuth.exchange(Map.delete(base, "code"))
    assert Accounts.list_api_keys(user.id) == []

    # None of those consumed the code.
    assert {:ok, _} = OAuth.exchange(base)
  end

  test "an invalid authorization request issues nothing" do
    user = insert_verified_user()
    {_verifier, challenge} = pkce()

    assert {:error, :unknown_client} =
             OAuth.authorize(user.id, %{request(challenge) | "client_id" => "nope"})

    refute Repo.exists?(from(c in AuthorizationCode, where: c.subject_id == ^user.id))
  end

  test "an expired code is refused" do
    user = insert_verified_user()
    {code, verifier} = code_for(user)

    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

    from(c in AuthorizationCode, where: c.subject_id == ^user.id)
    |> Repo.update_all(set: [expires_at: past])

    assert {:error, :invalid_grant} = OAuth.exchange(token_request(code, verifier))
  end

  # The ordering rule, kept on purpose: the code is consumed before the key
  # is minted, so a failed mint is :server_error with the code spent.
  test "a mint that fails is :server_error, and the code is consumed" do
    user = insert_verified_user()
    {code, verifier} = code_for(user)

    stub(Accounts, :create_api_key, fn _user_id, _name, _opts -> {:error, :database_down} end)
    assert {:error, :server_error} = OAuth.exchange(token_request(code, verifier))

    # Spent: a retry is a second exchange of a used code.
    assert [%AuthorizationCode{used_at: %DateTime{}}] =
             Repo.all(from(c in AuthorizationCode, where: c.subject_id == ^user.id))

    assert {:error, :invalid_grant} = OAuth.exchange(token_request(code, verifier))
  end

  test "the row stores the subject in user_id and only the code's hash" do
    user = insert_verified_user()
    {code, _verifier} = code_for(user)

    %{rows: [[stored_subject, code_hash]]} =
      Repo.query!(
        "SELECT user_id::text, code_hash FROM oauth_authorization_codes WHERE user_id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    assert stored_subject == user.id
    assert code_hash == Base.encode16(:crypto.hash(:sha256, code), case: :lower)
  end

  test "pkce_verify/2 is S256 and total" do
    {v, c} = pkce()
    assert Codes.pkce_verify(v, c)
    refute Codes.pkce_verify(v <> "a", c)
    refute Codes.pkce_verify(nil, c)
    refute Codes.pkce_verify(v, nil)
    refute Codes.pkce_verify(v, "short")
  end
end
