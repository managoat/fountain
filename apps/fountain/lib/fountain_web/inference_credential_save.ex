defmodule FountainWeb.InferenceCredentialSave do
  @moduledoc """
  Validate-then-persist an inference credential from a LiveView, with the
  messages the user sees. One place for the doors that collect keys (the
  credentials page, the agent form's just-in-time prompt),
  so every one validates against the provider first and audits the save
  with the socket's attribution (#546).
  """

  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Validator

  @type outcome :: {:ok, String.t()} | {:error, String.t()}

  @doc "Validate `value` against `provider`, persist it for the socket's user, and say what happened."
  @spec save(Phoenix.LiveView.Socket.t(), atom(), String.t() | nil, binary() | nil) :: outcome
  def save(socket, provider, value, set_id \\ nil) do
    value = String.trim(value || "")

    with {:ok, _set} <- selected_set(socket.assigns.user_id, set_id) do
      if value == "" do
        {:error, "Paste a value before saving."}
      else
        validate_and_persist(socket, provider, value, set_id)
      end
    end
  end

  defp validate_and_persist(socket, provider, value, set_id) do
    case Validator.validate(provider, value) do
      :ok ->
        case persist(socket, provider, value, set_id) do
          {:ok, _} -> {:ok, "Saved and validated."}
          {:error, reason} -> {:error, "Could not save: #{inspect(reason)}"}
        end

      {:error, :invalid, %{status: status}} ->
        {:error,
         "Provider rejected the credential (HTTP #{status}). Check that you copied the full token."}

      {:error, :timeout} ->
        {:error, "Validation timed out. Try again."}

      {:error, reason} ->
        {:error, "Could not reach provider (#{inspect(reason)})."}
    end
  end

  defp selected_set(_user_id, set_id) when set_id in [nil, ""], do: {:ok, nil}

  defp selected_set(user_id, set_id) do
    case InferenceCredentials.get_set(set_id, user_id) do
      nil ->
        {:error, "That credential set is no longer available. Choose another set before saving."}

      set ->
        {:ok, set}
    end
  end

  defp persist(socket, provider, value, set_id) do
    user_id = socket.assigns.user_id

    # Validate against the current tenant again after the provider request:
    # the chosen set may have been deleted while that request was in flight.
    with {:ok, set} <- selected_set(user_id, set_id),
         {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      opts = FountainWeb.Audited.attribution(socket)

      case set do
        nil -> InferenceCredentials.put_credential(user_id, dek, provider, value, opts)
        set -> InferenceCredentials.put_credential_in(set, dek, provider, value, opts)
      end
      |> case do
        {:error, :not_found} ->
          {:error,
           "That credential set is no longer available. Choose another set before saving."}

        result ->
          result
      end
    end
  rescue
    Ecto.StaleEntryError ->
      {:error, "That credential set is no longer available. Choose another set before saving."}
  end

  @doc "Human names for the providers and credentials the forms talk about."
  @spec label(atom() | String.t()) :: String.t()
  def label(:anthropic_api_key), do: "Anthropic API key"
  def label(:claude_code_oauth_token), do: "Claude OAuth token"
  def label(:openai_api_key), do: "OpenAI API key"
  def label(:gemini_api_key), do: "Gemini API key"
  def label("anthropic"), do: "Anthropic"
  def label("openai"), do: "OpenAI"
  def label("google"), do: "Google"
  def label(other), do: to_string(other)

  @doc "Where to get one."
  @spec source(atom()) :: String.t()
  def source(:anthropic_api_key), do: "console.anthropic.com"
  def source(:claude_code_oauth_token), do: "`claude setup-token`"
  def source(:openai_api_key), do: "platform.openai.com/api-keys"
  def source(:gemini_api_key), do: "aistudio.google.com/apikey"
  def source(_), do: ""
end
