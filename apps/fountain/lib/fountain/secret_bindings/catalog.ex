defmodule Fountain.SecretBindings.Catalog do
  @moduledoc """
  Agent Vault's service catalog (35 presets, 0.39.1), embedded so the console
  can prefill a binding from a secret's name: `STRIPE_SECRET_KEY` suggests
  `api.stripe.com` as a bearer, and so on.

  Suggestions, never rules: the tenant still saves the binding, and can
  change any field. Three presets are not directly usable as bindings and
  are marked `usable: false` — `aws-s3` needs SigV4 signing, `jira` and
  `twilio` are basic auth where the suggested key is the password and the
  username is the tenant's own. A vendor `passthrough` preset, one that
  substitutes a placeholder rather than adding a header, maps to our
  `substitute` shape.

  Read at compile time from `priv/broker/service_catalog.json`, which ships
  in the release like the rest of `priv`.
  """

  @path Path.join(:code.priv_dir(:fountain) |> to_string(), "broker/service_catalog.json")
  @external_resource @path

  @unusable ~w(aws-s3 jira twilio)

  @presets @path
           |> File.read!()
           |> Jason.decode!()
           |> Enum.map(fn e ->
             %{
               id: e["id"],
               name: e["name"],
               host: e["host"],
               description: e["description"],
               auth_type:
                 e["auth_type"]
                 |> String.replace("-", "_")
                 |> String.replace("passthrough", "substitute"),
               suggested_key: e["suggested_credential_key"],
               header: e["header"],
               prefix: e["prefix"],
               headers: e["headers"] || %{},
               usable: e["id"] not in @unusable
             }
           end)

  @type preset :: %{
          id: String.t(),
          name: String.t(),
          host: String.t(),
          description: String.t() | nil,
          auth_type: String.t(),
          suggested_key: String.t() | nil,
          header: String.t() | nil,
          prefix: String.t() | nil,
          headers: map(),
          usable: boolean()
        }

  @doc "Every preset, in the catalog's order."
  @spec presets() :: [preset()]
  def presets, do: @presets

  @spec get(String.t()) :: preset() | nil
  def get(id), do: Enum.find(@presets, &(&1.id == id))

  @doc "Presets whose suggested credential key is this one. Usually zero or one."
  @spec for_key(String.t()) :: [preset()]
  def for_key(key) when is_binary(key), do: Enum.filter(@presets, &(&1.suggested_key == key))
end
