defmodule Managoat.OAuth.Device do
  @moduledoc """
  The device-authorization half of the grant state machine (RFC 8628
  shape). A poller that cannot hold a password starts a grant, shows a human
  a short code and the console's approval page, and polls with its own
  high-entropy device code until a signed-in subject approves. Fifteen
  minutes to live, single use, one poll per interval.

  Whether the subject may collect a key, minting it, and the audit trail are
  `Fountain.OAuth.Host`'s. The poll asks the host about the subject **before**
  it consumes the grant, so a refused subject gets `access_denied` and the
  grant stays approved and unconsumed; a mint that fails after consumption
  answers `:server_error` with the grant spent.
  """

  import Ecto.Query, warn: false

  alias Fountain.OAuth.Host
  alias Fountain.Repo
  alias Managoat.OAuth.{Codes, DeviceGrant}

  @device_ttl_seconds 900
  @device_interval_seconds 5
  # RFC 8628's suggested consonant alphabet: no vowels (no words, no
  # accidental profanity), no ambiguous glyphs. 20^8 codes for a
  # fifteen-minute, rate-limited window.
  @user_code_alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"
  @user_code_length 8
  @alphabet_size length(@user_code_alphabet)
  # The column is varchar(64); the minted key's name allows 200.
  @client_name_max 64
  @unbiased_byte_limit 256 - rem(256, @alphabet_size)

  @doc """
  Start a device grant. Returns `{:ok, %{device_code, user_code, expires_in,
  interval}}`: `device_code` is raw (only its hash is stored) and stays on
  the polling machine; `user_code` is formatted `XXXX-XXXX` for a human to
  type. Deliberately unaudited: nothing has happened to any subject yet.

  `:client_name` is what the client calls itself ("Arugula on geek"). It is
  passed through `sanitize_client_name/1` and stored on the grant, so the
  approval page can show it and the minted key is named after it.
  """
  @spec start(keyword()) ::
          {:ok,
           %{
             device_code: String.t(),
             user_code: String.t(),
             expires_in: pos_integer(),
             interval: pos_integer()
           }}
          | {:error, :server_error}
  def start(opts \\ []) do
    client_name = opts |> Keyword.get(:client_name) |> sanitize_client_name()
    insert_grant(Codes.random_token(), client_name, _attempts_left = 3)
  end

  @doc """
  Make a client-supplied name safe to show and to name a key with: invalid
  UTF-8 replaced, control, format (bidi overrides, zero-width) and separator
  characters each run collapsed to one space, trimmed, and cut to
  #{@client_name_max} codepoints. `nil` for `nil` or for nothing left.
  """
  @spec sanitize_client_name(String.t() | nil) :: String.t() | nil
  def sanitize_client_name(nil), do: nil

  def sanitize_client_name(name) when is_binary(name) do
    name
    |> String.replace_invalid(" ")
    |> String.replace(~r/[\p{C}\p{Z}]+/u, " ")
    |> String.trim()
    |> String.codepoints()
    |> Enum.take(@client_name_max)
    |> Enum.join()
    |> String.trim_trailing()
    |> case do
      "" -> nil
      sanitized -> sanitized
    end
  end

  defp insert_grant(_raw, _client_name, 0), do: {:error, :server_error}

  defp insert_grant(raw, client_name, attempts_left) do
    user_code = generate_user_code()

    %DeviceGrant{}
    |> DeviceGrant.changeset(%{
      device_code_hash: Codes.hash(raw),
      user_code: user_code,
      client_name: client_name,
      expires_at: Codes.now_s() |> DateTime.add(@device_ttl_seconds, :second)
    })
    |> Repo.insert()
    |> case do
      {:ok, _grant} ->
        {:ok,
         %{
           device_code: raw,
           user_code: format_user_code(user_code),
           expires_in: @device_ttl_seconds,
           interval: @device_interval_seconds
         }}

      # A user_code collision (20^8 space, so effectively never) — roll again.
      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :user_code),
          do: insert_grant(raw, client_name, attempts_left - 1),
          else: {:error, :server_error}
    end
  end

  defp generate_user_code do
    for _ <- 1..@user_code_length, into: "" do
      <<Enum.at(@user_code_alphabet, random_alphabet_index())>>
    end
  end

  defp random_alphabet_index do
    <<byte>> = :crypto.strong_rand_bytes(1)

    # Reject the incomplete final group so every alphabet index has the same
    # probability; taking byte modulo the alphabet size directly would bias it.
    if byte < @unbiased_byte_limit,
      do: rem(byte, @alphabet_size),
      else: random_alphabet_index()
  end

  @doc ~S(Format a stored user code for humans: "BCDFGHJK" → "BCDF-GHJK".)
  @spec format_user_code(String.t()) :: String.t()
  def format_user_code(<<a::binary-size(4), b::binary-size(4)>>), do: a <> "-" <> b
  def format_user_code(code), do: code

  @doc "Normalize what a human typed: case, the display dash, stray spaces."
  @spec normalize_user_code(String.t()) :: String.t()
  def normalize_user_code(input) when is_binary(input) do
    input |> String.upcase() |> String.replace(~r/[^A-Z]/, "")
  end

  @doc """
  The pending, unexpired grant for a typed user code: what the approval page
  shows before the subject decides. `{:error, :not_found}` is one answer for
  unknown, expired and decided alike.
  """
  @spec get_for_approval(String.t()) :: {:ok, DeviceGrant.t()} | {:error, :not_found}
  def get_for_approval(input) when is_binary(input) do
    now = DateTime.utc_now()
    code = normalize_user_code(input)

    from(g in DeviceGrant,
      where:
        g.user_code == ^code and is_nil(g.approved_at) and is_nil(g.denied_at) and
          is_nil(g.used_at) and g.expires_at > ^now
    )
    |> Repo.one()
    |> case do
      %DeviceGrant{} = grant -> {:ok, grant}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The signed-in subject approves the grant behind a typed user code, binding
  the subject to it so the next poll mints a key. Conditional on the grant
  still being pending and unexpired, so approve, deny and expiry cannot race.
  Audits `:device_approved` through the host.
  """
  @spec approve(String.t(), binary(), keyword()) :: :ok | {:error, :not_found}
  def approve(input, subject, opts \\ []) when is_binary(subject) do
    decide(input, subject, [approved_at: Codes.now_s()], :device_approved, opts)
  end

  @doc "The signed-in subject denies the grant. Audits `:device_denied`."
  @spec deny(String.t(), binary(), keyword()) :: :ok | {:error, :not_found}
  def deny(input, subject, opts \\ []) when is_binary(subject) do
    decide(input, subject, [denied_at: Codes.now_s()], :device_denied, opts)
  end

  defp decide(input, subject, set, event, opts) do
    with {:ok, grant} <- get_for_approval(input) do
      from(g in DeviceGrant,
        where:
          g.id == ^grant.id and is_nil(g.approved_at) and is_nil(g.denied_at) and
            is_nil(g.used_at)
      )
      |> Repo.update_all(set: [{:subject_id, subject} | set])
      |> case do
        {1, _} ->
          _ = Host.audit(event, %{subject_id: subject, grant_id: grant.id}, opts)
          :ok

        {0, _} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  The poller asks with its device code. One of:

    * `{:ok, %{access_token, api_key}}`: approved, the subject accepted by
      the host, the grant consumed and a key minted (once: the conditional
      update that marks the grant used means two concurrent polls cannot
      both win)
    * `{:error, :authorization_pending}`: nobody has decided yet
    * `{:error, :slow_down}`: polled faster than the advertised interval
    * `{:error, :access_denied}`: denied, or the host refused the subject
      (the grant stays approved and unconsumed)
    * `{:error, :expired_token}`: the grant timed out
    * `{:error, :invalid_grant}`: unknown or already-consumed code
    * `{:error, :server_error}`: the key could not be minted
  """
  @spec poll(String.t(), keyword()) ::
          {:ok, %{access_token: String.t(), api_key: term()}}
          | {:error,
             :authorization_pending
             | :slow_down
             | :access_denied
             | :expired_token
             | :invalid_grant
             | :server_error}
  def poll(device_code, opts \\ []) when is_binary(device_code) do
    now = Codes.now_s()

    case Repo.get_by(DeviceGrant, device_code_hash: Codes.hash(device_code)) do
      nil ->
        {:error, :invalid_grant}

      %DeviceGrant{used_at: %DateTime{}} ->
        {:error, :invalid_grant}

      %DeviceGrant{denied_at: %DateTime{}} ->
        {:error, :access_denied}

      %DeviceGrant{} = grant ->
        if DateTime.compare(grant.expires_at, now) == :gt,
          do: poll_live(grant, now, opts),
          else: {:error, :expired_token}
    end
  end

  defp poll_live(%DeviceGrant{approved_at: nil} = grant, now, _opts) do
    threshold = DateTime.add(now, -(@device_interval_seconds - 1), :second)

    from(g in DeviceGrant,
      where: g.id == ^grant.id and (is_nil(g.last_polled_at) or g.last_polled_at <= ^threshold)
    )
    |> Repo.update_all(set: [last_polled_at: now])
    |> case do
      {1, _} -> {:error, :authorization_pending}
      {0, _} -> {:error, :slow_down}
    end
  end

  # Approved but bound to nobody: the approval and the subject were written
  # in one conditional update, so this is a row edited by hand. Refuse it.
  defp poll_live(%DeviceGrant{subject_id: nil}, _now, _opts),
    do: {:error, :invalid_grant}

  defp poll_live(%DeviceGrant{} = grant, now, opts) do
    # The host is asked before the grant is consumed, on purpose: a subject
    # the host no longer allows (unverified since approving, say) gets
    # access_denied and the grant stays approved, unconsumed. There is a
    # test for it.
    case Host.subject_allowed?(grant.subject_id) do
      :ok -> consume_and_issue(grant, now, opts)
      {:error, _} -> {:error, :access_denied}
    end
  end

  defp consume_and_issue(grant, now, opts) do
    from(g in DeviceGrant, where: g.id == ^grant.id and is_nil(g.used_at))
    |> Repo.update_all(set: [used_at: now])
    |> case do
      {0, _} ->
        {:error, :invalid_grant}

      {1, _} ->
        descriptor = %{
          type: :device,
          id: grant.id,
          client_id: nil,
          client_name: grant.client_name,
          expires_at: nil
        }

        case Host.issue_token(grant.subject_id, descriptor, opts) do
          {:ok, %{access_token: access_token, token: token}} ->
            {:ok, %{access_token: access_token, api_key: token}}

          {:error, _} ->
            {:error, :server_error}
        end
    end
  end
end
