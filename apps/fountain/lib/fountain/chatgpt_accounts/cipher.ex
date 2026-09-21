defmodule Fountain.ChatGPTAccounts.Cipher do
  @moduledoc false

  require Logger

  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT.Account

  # Keep the deployed platform format. A user's blob has an AAD naming its
  # owner, its grant and its field, preventing token-field swaps, cross-owner
  # copies and, now that a user may hold several grants (ADR 0060), a copy
  # between two grants of one owner. The grant id went into the AAD before
  # any owned row existed; adding it later would have been a data migration.
  def encrypt_platform_token(token) when is_binary(token), do: Crypto.encrypt_platform(token)

  @doc false
  def encrypt_refresh_tokens(%Account{} = account, %{access_token: access} = tokens)
      when is_binary(access) do
    fields =
      case tokens[:refresh_token] do
        refresh when is_binary(refresh) and refresh != "" ->
          %{access_token: access, refresh_token: refresh}

        _ ->
          %{access_token: access}
      end

    encrypt_fields(account.user_id, account.id, fields)
  end

  defp encrypt_fields(nil, _grant_id, fields) do
    {:ok,
     Map.new(fields, fn {field, token} ->
       {ciphertext_field(field), encrypt_platform_token(token)}
     end)}
  end

  defp encrypt_fields(user_id, grant_id, fields)
       when is_binary(user_id) and is_binary(grant_id) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      {:ok,
       Map.new(fields, fn {field, token} ->
         {ciphertext_field(field), Crypto.encrypt(token, dek, aad(user_id, grant_id, field))}
       end)}
    end
  end

  defp ciphertext_field(:access_token), do: :access_token_ciphertext
  defp ciphertext_field(:refresh_token), do: :refresh_token_ciphertext

  @doc """
  Both tokens for the row `grant_id` of `user_id`. The id is part of what the
  ciphertext is bound to, so the caller chooses it before the row exists and
  inserts the row under that id.
  """
  @spec encrypt_user_tokens(String.t(), Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, atom()}
  def encrypt_user_tokens(user_id, grant_id, %{access_token: access, refresh_token: refresh})
      when is_binary(user_id) and is_binary(grant_id) and is_binary(access) and
             is_binary(refresh) do
    encrypt_fields(user_id, grant_id, %{access_token: access, refresh_token: refresh})
  end

  @spec decrypt_token(Account.t(), :access_token | :refresh_token) ::
          {:ok, String.t()} | {:error, atom()}
  def decrypt_token(%Account{} = account, field) when field in [:access_token, :refresh_token] do
    case ciphertext(account, field) do
      nil -> {:error, :no_token}
      blob -> decrypt(account, field, blob)
    end
  end

  defp ciphertext(account, :access_token), do: account.access_token_ciphertext
  defp ciphertext(account, :refresh_token), do: account.refresh_token_ciphertext

  defp decrypt(%Account{user_id: nil}, field, blob),
    do: normalize(Crypto.decrypt_platform(blob), :platform, field)

  defp decrypt(%Account{user_id: user_id, id: grant_id}, field, blob)
       when is_binary(user_id) and is_binary(grant_id) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      normalize(
        Crypto.decrypt(blob, dek, aad(user_id, grant_id, field)),
        {user_id, grant_id},
        field
      )
    end
  end

  defp normalize({:ok, value}, _owner, _field), do: {:ok, value}

  # A key that no longer opens the stored blob is the one failure here an
  # operator has to be told about, because nothing else says it: the grant
  # stops working, codex falls back to the platform API key, and the status
  # read never decrypts so the admin page still says "active".
  # `Fountain.PlatformInference` warns on exactly this for its keys.
  defp normalize(:error, :platform, field) do
    Logger.warning(
      "platform chatgpt: the stored #{field} does not decrypt under MASTER_SECRETS_KEY; " <>
        "reconnect at /admin/inference"
    )

    {:error, :undecryptable}
  end

  # With several grants per owner the line has to say which one.
  defp normalize(:error, {user_id, grant_id}, field) do
    Logger.warning(
      "chatgpt grant #{grant_id} of #{user_id}: the stored #{field} does not decrypt under " <>
        "the tenant key; the owner must reconnect the account"
    )

    {:error, :undecryptable}
  end

  defp aad(user_id, grant_id, field),
    do: "fountain.chatgpt_grant:#{user_id}:#{grant_id}:#{field}"
end
