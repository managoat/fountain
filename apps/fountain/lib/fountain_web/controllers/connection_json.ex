defmodule FountainWeb.ConnectionJSON do
  @moduledoc "JSON views for connections (ADR 0085). Never a token, a secret or login state."

  alias Fountain.Connections.Connection

  def index(%{connections: connections}), do: %{data: Enum.map(connections, &data/1)}

  def show(%{connection: connection}), do: data(connection)

  def login(%{connection: connection, authorize_url: url}),
    do: %{connection: data(connection), authorize_url: url}

  @doc false
  def data(%Connection{} = c) do
    %{
      id: c.id,
      url: c.url,
      resource: c.resource,
      status: c.status,
      revoked_reason: c.revoked_reason,
      issuer: c.issuer,
      registration: c.registration,
      client_id: c.client_id,
      scopes: c.scopes,
      expires_at: c.expires_at,
      last_refreshed_at: c.last_refreshed_at,
      created_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end
end
