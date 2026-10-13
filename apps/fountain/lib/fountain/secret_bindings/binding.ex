defmodule Fountain.SecretBindings.Binding do
  @moduledoc """
  One host a tenant's secret is attached to at the egress broker, and how
  (ADR 0019 gate 1b).

  Keyed by the secret's *name*, not by a row in `secrets` or `vault_secrets`:
  brokering runs on the merged map, where only the name survives, and a
  binding is a fact about the credential wherever it is stored. Several rows
  per key are normal — GitHub is `api.github.com` as a bearer *and*
  `github.com` as basic `x-access-token`.

  The validation mirrors Agent Vault 0.39.1's `broker.Validate` so a binding
  that saves here is one the broker accepts; the messages are ours, the rules
  are theirs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @auth_types ~w(substitute bearer basic api_key custom)
  @key_re ~r/^[A-Z][A-Z0-9_]*$/
  @header_name_re ~r/^[a-zA-Z0-9-]+$/
  @host_label_re ~r/^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/
  @template_ref_re ~r/\{\{\s*(\w+)\s*\}\}/
  @internal_hosts ~w(localhost localhost.localdomain internal kubernetes kubernetes.default metadata.google.internal metadata.google instance-data)
  @path_forbidden [" ", "?", "#", "[", "]", "\\", "|", "<", ">", "\""]

  @type t :: %__MODULE__{}

  schema "secret_bindings" do
    field :key, :string
    field :host, :string
    field :auth_type, :string
    field :header, :string
    field :prefix, :string
    field :username, :string
    field :headers, :map, default: %{}
    field :enabled, :boolean, default: true
    belongs_to :user, Fountain.Accounts.User
    timestamps(type: :utc_datetime)
  end

  @doc """
  The shapes a binding can take. `substitute` is the default and needs no
  other field: the broker replaces the secret's placeholder wherever it
  appears in a request to the host (header, query, path, body), so the
  agent sends whatever shape the API wants and never has to be told how. The
  explicit shapes add a header the agent did not send, or, for `basic`,
  cover the one case substitution cannot: a value the client base64-encodes
  before it leaves.
  """
  def auth_types, do: @auth_types

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [
      :key,
      :host,
      :auth_type,
      :header,
      :prefix,
      :username,
      :headers,
      :enabled,
      :user_id
    ])
    |> validate_required([:key, :host, :auth_type, :user_id])
    |> update_change(:key, &String.trim/1)
    |> update_change(:host, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:key, @key_re, message: "must be UPPER_SNAKE_CASE, like STRIPE_KEY")
    |> validate_length(:key, max: 200)
    |> validate_inclusion(:auth_type, @auth_types)
    |> validate_host()
    |> validate_auth_fields()
    |> unique_constraint([:user_id, :key, :host],
      error_key: :host,
      message: "this secret is already bound to that host"
    )
  end

  # ── host: `host[:port][/path]`, the one box the broker itself takes ──────

  defp validate_host(changeset) do
    case get_change(changeset, :host) do
      nil -> changeset
      pattern -> validate_host_pattern(changeset, pattern)
    end
  end

  defp validate_host_pattern(changeset, pattern) do
    {host_port, path} = split_path(pattern)
    {host, port} = split_port(host_port)

    errors =
      host_errors(host) ++ port_errors(port) ++ path_errors(path)

    Enum.reduce(errors, changeset, &add_error(&2, :host, &1))
  end

  defp split_path(pattern) do
    case String.split(pattern, "/", parts: 2) do
      [host] -> {host, ""}
      [host, rest] -> {host, "/" <> rest}
    end
  end

  defp split_port(host_port) do
    case String.split(host_port, ":", parts: 2) do
      [host] -> {host, nil}
      [host, port] -> {host, port}
    end
  end

  defp host_errors(""), do: ["host is required"]

  defp host_errors(host) do
    cond do
      String.contains?(host, ["@", "?", "#", " "]) or String.match?(host, ~r/[[:cntrl:]]/) ->
        ["host contains a character that is not allowed"]

      ip?(host) ->
        ["host must be a hostname, not an IP address"]

      host == "*" ->
        ["a bare wildcard is not allowed"]

      String.starts_with?(host, "*") and not String.starts_with?(host, "*.") ->
        ["a wildcard must be in the form *.example.com"]

      String.starts_with?(host, "*.") ->
        rest = String.trim_leading(host, "*.")

        cond do
          length(String.split(rest, ".")) < 2 ->
            ["a wildcard must have at least two domain levels, like *.example.com"]

          not String.match?(rest, @host_label_re) ->
            ["invalid hostname in the wildcard pattern"]

          true ->
            []
        end

      host in @internal_hosts ->
        ["host is a local or internal name and is not allowed"]

      not String.match?(host, @host_label_re) ->
        ["host must be a hostname with a domain, like api.example.com"]

      true ->
        []
    end
  end

  defp ip?(host), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))

  defp port_errors(nil), do: []

  defp port_errors(port) do
    case Integer.parse(port) do
      {n, ""} when n in 1..65_535 -> []
      _ -> ["port must be a number between 1 and 65535"]
    end
  end

  defp path_errors(""), do: []

  defp path_errors(path) do
    cond do
      String.length(path) > 256 -> ["path is too long (256 characters at most)"]
      String.contains?(path, "**") -> ["path must not contain ** (only a single * glob)"]
      String.match?(path, ~r/[[:cntrl:]]/) -> ["path must not contain control characters"]
      String.contains?(path, @path_forbidden) -> ["path contains a character that is not allowed"]
      true -> []
    end
  end

  # ── auth: only the fields of the chosen type, which is what the broker
  # insists on (a stale field from a previous choice is a 400 there) ────────

  defp validate_auth_fields(changeset) do
    case get_field(changeset, :auth_type) do
      "substitute" ->
        changeset |> clear([:header, :prefix, :username]) |> put_change(:headers, %{})

      "bearer" ->
        changeset |> clear([:header, :prefix, :username]) |> put_change(:headers, %{})

      "basic" ->
        changeset
        |> validate_required([:username])
        |> clear([:header, :prefix])
        |> put_change(:headers, %{})

      "api_key" ->
        changeset
        |> default_header()
        |> validate_header_name()
        |> clear([:username])
        |> put_change(:headers, %{})

      "custom" ->
        changeset |> clear([:header, :prefix, :username]) |> validate_custom_headers()

      _ ->
        changeset
    end
  end

  defp clear(changeset, fields), do: Enum.reduce(fields, changeset, &put_change(&2, &1, nil))

  defp default_header(changeset) do
    case get_field(changeset, :header) do
      nil -> put_change(changeset, :header, "Authorization")
      "" -> put_change(changeset, :header, "Authorization")
      _ -> changeset
    end
  end

  defp validate_header_name(changeset) do
    validate_format(changeset, :header, @header_name_re,
      message: "only letters, digits and hyphens are allowed"
    )
  end

  defp validate_custom_headers(changeset) do
    headers = get_field(changeset, :headers) || %{}

    cond do
      headers == %{} ->
        add_error(changeset, :headers, "custom auth needs at least one header")

      not Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end) ->
        add_error(changeset, :headers, "must be header names to templates")

      true ->
        Enum.reduce(headers, changeset, fn {name, template}, cs ->
          cond do
            not String.match?(name, @header_name_re) ->
              add_error(
                cs,
                :headers,
                "header #{inspect(name)}: only letters, digits and hyphens are allowed"
              )

            Enum.any?(template_refs(template), &(not String.match?(&1, @key_re))) ->
              add_error(
                cs,
                :headers,
                "header #{inspect(name)}: every {{ KEY }} must be UPPER_SNAKE_CASE"
              )

            true ->
              cs
          end
        end)
    end
  end

  @doc "The credential keys a custom header template refers to, `{{ KEY }}`."
  @spec template_refs(String.t()) :: [String.t()]
  def template_refs(template) when is_binary(template) do
    @template_ref_re |> Regex.scan(template) |> Enum.map(fn [_, k] -> k end)
  end
end
