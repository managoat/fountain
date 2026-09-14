defmodule Fountain.Connections.Provider do
  @moduledoc """
  Where a connection's tokens come from (#1186). Two kinds of tenant row:

    * `oauth2` — the tenant registered an app at a service (GitHub, Slack,
      Notion, Linear…) and gave Fountain the client id and secret, plus the
      authorize / token / revoke endpoints and the scopes. Fountain cannot own
      an app on every provider, and the restricted scopes need per-app
      verification anyway, so the tenant's app is the only one that works.
    * `mcp` — a remote MCP server that implements the MCP authorization
      spec. `Managoat.McpAuth` found its authorization
      server, and registered a client there when the server offered RFC 7591
      registration; the tenant pasted one otherwise.

  The **platform** providers (Google, Microsoft, Slack) are the same
  struct, built from config by `Fountain.Connections.Platform`, with
  `user_id: nil` and their slug as the reserved id. One code path serves
  every kind — `Managoat.McpAuth.Client`, which `Fountain.Connections.OAuth`
  builds a config for — because what differs per service is data on the
  struct, including the two things that used to be code (#2152):

    * `authorize_params` — extra authorize-URL parameters, merged over the
      standard ones (so a provider may override `scope` itself). Google's
      offline pair; Slack's `user_scope`.
    * `token_body_nest` — the key under which the provider nests the user's
      grant in its token response (Slack: `authed_user`). The OAuth client
      lifts `access_token`, `refresh_token`, `expires_in` and `scope` from
      there to the RFC 6749 top level.

  Both are virtual: the builder of a config-backed provider sets them, and a
  tenant row has neither.

  The client secret is DEK-encrypted like a vault secret and never leaves
  the server; the access token a connection on this provider yields is
  brokered under `env_key` (a second account takes `env_key_2`) with an
  implicit bearer binding to `token_hosts`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Crypto
  alias Managoat.McpAuth.UrlGuard

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(oauth2 mcp)
  @token_endpoint_auths ~w(client_secret_post client_secret_basic none)
  @client_sources ~w(dcr manual)
  @slug_re ~r/^[a-z][a-z0-9-]{1,63}$/
  @env_key_re ~r/^[A-Z][A-Z0-9_]*$/
  @host_re ~r/^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/

  @type t :: %__MODULE__{}

  schema "connection_providers" do
    field :slug, :string
    field :name, :string
    field :kind, :string
    field :authorize_url, :string
    field :token_url, :string
    field :revoke_url, :string
    field :userinfo_url, :string
    field :account_label_path, :string
    field :scopes, {:array, :string}, default: []
    field :client_id, :string
    field :client_secret_ciphertext, :binary, redact: true
    field :client_secret, :string, virtual: true, redact: true
    field :token_endpoint_auth, :string, default: "client_secret_post"
    field :pkce, :boolean, default: true
    field :env_key, :string
    field :token_hosts, {:array, :string}, default: []
    field :mcp_url, :string
    field :issuer, :string
    field :mcp_metadata, :map, default: %{}
    field :client_source, :string
    field :authorize_params, :map, virtual: true, default: %{}
    field :token_body_nest, :string, virtual: true
    belongs_to :user, Fountain.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def token_endpoint_auths, do: @token_endpoint_auths
  def client_sources, do: @client_sources
  def reserved_slugs, do: Fountain.Connections.Platform.slugs()

  @doc "True for the config-backed platform provider, which has no row."
  def platform?(%__MODULE__{user_id: nil}), do: true
  def platform?(_), do: false

  @doc """
  A tenant's `oauth2` or `mcp` provider. `attrs` carries the plaintext
  `client_secret`, encrypted with the tenant `dek` before it is persisted;
  an update that leaves it blank keeps the stored one.
  """
  def changeset(provider, attrs, dek) when is_binary(dek) do
    provider
    |> cast(attrs, [
      :user_id,
      :slug,
      :name,
      :kind,
      :authorize_url,
      :token_url,
      :revoke_url,
      :userinfo_url,
      :account_label_path,
      :scopes,
      :client_id,
      :client_secret,
      :token_endpoint_auth,
      :pkce,
      :env_key,
      :token_hosts,
      :mcp_url,
      :issuer,
      :mcp_metadata,
      :client_source
    ])
    |> derive_slug()
    |> derive_name()
    |> derive_env_key()
    |> validate_required([:user_id, :slug, :name, :kind, :env_key])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:token_endpoint_auth, @token_endpoint_auths)
    |> validate_inclusion(:client_source, @client_sources)
    |> validate_format(:slug, @slug_re,
      message: "must be lowercase letters, digits and dashes, 2 to 64 characters"
    )
    |> validate_exclusion(:slug, reserved_slugs(), message: "is a platform provider")
    |> validate_format(:env_key, @env_key_re, message: "must be UPPER_SNAKE_CASE")
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:scopes, max: 64)
    |> validate_urls()
    |> validate_token_hosts()
    |> validate_kind_fields()
    |> encrypt_secret(dek)
    |> unique_constraint([:user_id, :slug], error_key: :slug)
    |> unique_constraint([:user_id, :env_key], error_key: :env_key)
  end

  # `github` → `GITHUB_ACCESS_TOKEN`, the name a stdio server expects to read.
  defp derive_env_key(changeset) do
    case {get_field(changeset, :env_key), get_field(changeset, :slug)} do
      {blank, slug} when blank in [nil, ""] and is_binary(slug) ->
        key = slug |> String.upcase() |> String.replace(~r/[^A-Z0-9]+/, "_")
        put_change(changeset, :env_key, key <> "_ACCESS_TOKEN")

      _ ->
        changeset
    end
  end

  # An MCP provider is named by its server's host when the tenant gave no slug.
  defp derive_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :mcp_url)} do
      {blank, url} when blank in [nil, ""] and is_binary(url) ->
        slug =
          (URI.parse(url).host || "")
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")
          |> String.slice(0, 64)

        put_change(changeset, :slug, slug)

      _ ->
        changeset
    end
  end

  # A provider with no name is named after its slug.
  defp derive_name(changeset) do
    case {get_field(changeset, :name), get_field(changeset, :slug)} do
      {blank, slug} when blank in [nil, ""] and is_binary(slug) and slug != "" ->
        put_change(changeset, :name, slug)

      _ ->
        changeset
    end
  end

  defp validate_urls(changeset) do
    Enum.reduce(
      [:authorize_url, :token_url, :revoke_url, :userinfo_url, :mcp_url, :issuer],
      changeset,
      fn field, cs -> cs |> validate_length(field, max: 2048) |> validate_url(field) end
    )
  end

  # The reusable guard deliberately has no Ecto dependency. This single
  # changeset adapter belongs to the Fountain schema that consumes it.
  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, url ->
      case UrlGuard.check(url) do
        :ok -> []
        {:error, reason} -> [{field, UrlGuard.message(reason)}]
      end
    end)
  end

  # Where the token goes as a bearer. Hostnames only: a bare `*` (or any
  # wildcard) would attach the token to every host the sandbox reaches,
  # which is the leak the broker exists to prevent.
  defp validate_token_hosts(changeset) do
    validate_change(changeset, :token_hosts, fn :token_hosts, hosts ->
      cond do
        length(hosts) > 32 ->
          [token_hosts: "at most 32 hosts"]

        Enum.any?(hosts, &String.contains?(&1, "*")) ->
          [token_hosts: "may not contain a wildcard"]

        Enum.any?(hosts, &(not Regex.match?(@host_re, &1))) ->
          [token_hosts: "must be hostnames"]

        true ->
          []
      end
    end)
  end

  defp validate_kind_fields(changeset) do
    case get_field(changeset, :kind) do
      "oauth2" ->
        changeset
        |> validate_required([:authorize_url, :token_url, :client_id])
        |> validate_secret_present()

      "mcp" ->
        # Endpoints come from discovery, which fills them before insert. A
        # `none` client (public, PKCE-only) has no secret, so it is not required.
        changeset
        |> validate_required([:mcp_url])
        |> put_change(:pkce, true)

      _ ->
        changeset
    end
  end

  # A confidential client needs its secret at least once. `none` is the
  # public-client shape and carries no secret.
  defp validate_secret_present(changeset) do
    auth = get_field(changeset, :token_endpoint_auth)
    stored = changeset.data.client_secret_ciphertext

    if auth != "none" and is_nil(stored) and blank?(get_change(changeset, :client_secret)),
      do: add_error(changeset, :client_secret, "can't be blank"),
      else: changeset
  end

  defp blank?(v), do: v in [nil, ""]

  defp encrypt_secret(changeset, dek) do
    case get_change(changeset, :client_secret) do
      blank when blank in [nil, ""] -> delete_change(changeset, :client_secret)
      value -> put_change(changeset, :client_secret_ciphertext, Crypto.encrypt(value, dek))
    end
  end
end
