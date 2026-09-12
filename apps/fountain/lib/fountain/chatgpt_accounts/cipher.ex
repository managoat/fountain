defmodule Fountain.ChatGPTAccounts.Cipher do
  @moduledoc false

  require Logger

  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT.Account

  # Keep the deployed platform format. A tenant blob has an owner- and
  # field-specific AAD, preventing token-field swaps and cross-owner copies.
  def encrypt_platform_token(token) when is_binary(token), do: Crypto.encrypt_platform(token)

  @spec encrypt_user_tokens(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def encrypt_user_tokens(user_id, %{access_token: access, refresh_token: refresh})
      when is_binary(user_id) and is_binary(access) and is_binary(refresh) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      {:ok,
       %{
         access_token_ciphertext: Crypto.encrypt(access, dek, aad(user_id, :access_token)),
         refresh_token_ciphertext: Crypto.encrypt(refresh, dek, aad(user_id, :refresh_token))
       }}
    end
  end

  @spec decrypt_token(Account.t(), :access_token | :refresh_token) ::
          {:ok, String.t()} | {:error, atom()}
  def decrypt_token(%Account{} = account, field) when field in [:access_token, :refresh_token] do
    case ciphertext(account, field) do
      nil -> {:error, :no_token}
      blob -> decrypt(account.user_id, field, blob)
    end
  end

  defp ciphertext(account, :access_token), do: account.access_token_ciphertext
  defp ciphertext(account, :refresh_token), do: account.refresh_token_ciphertext

  defp decrypt(nil, field, blob),
    do: normalize(Crypto.decrypt_platform(blob), nil, field)

  defp decrypt(user_id, field, blob) when is_binary(user_id) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      normalize(Crypto.decrypt(blob, dek, aad(user_id, field)), user_id, field)
    end
  end

  defp normalize({:ok, value}, _owner, _field), do: {:ok, value}

  # A key that no longer opens the stored blob is the one failure here an
  # operator has to be told about, because nothing else says it: the grant
  # stops working, codex falls back to the platform API key, and the status
  # read never decrypts so the admin page still says "active".
  # `Fountain.PlatformInference` warns on exactly this for its keys.
  defp normalize(:error, nil, field) do
    Logger.warning(
      "platform chatgpt: the stored #{field} does not decrypt under MASTER_SECRETS_KEY; " <>
        "reconnect at /admin/inference"
    )

    {:error, :undecryptable}
  end

  defp normalize(:error, user_id, field) do
    Logger.warning(
      "chatgpt grant #{user_id}: the stored #{field} does not decrypt under the tenant key; " <>
        "the owner must reconnect the account"
    )

    {:error, :undecryptable}
  end

  defp aad(user_id, field), do: "fountain.chatgpt_grant:#{user_id}:#{field}"
end
