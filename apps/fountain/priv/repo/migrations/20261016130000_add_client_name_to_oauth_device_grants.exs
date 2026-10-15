defmodule Fountain.Repo.Migrations.AddClientNameToOauthDeviceGrants do
  use Ecto.Migration

  def change do
    alter table(:oauth_device_grants) do
      # What the starting client called itself (`client_name` on
      # `POST /api/auth/device`), already sanitized and bounded. Shown on the
      # approval page as a claim and used to name the minted key. Null when
      # the client sent none.
      add :client_name, :string, size: 64
    end
  end
end
