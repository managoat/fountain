defmodule Fountain.Workers.SecretExpirySweeperConfigTest do
  # Sets the global notice window, so it runs after the async tests (#1932).
  use Fountain.DataCase, async: false

  import Swoosh.TestAssertions

  alias Fountain.Workers.SecretExpirySweeper

  test "notice_days 0 disables the sweep" do
    previous = Application.fetch_env(:fountain, :secret_expiry_notice_days)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fountain, :secret_expiry_notice_days, value)
        :error -> Application.delete_env(:fountain, :secret_expiry_notice_days)
      end
    end)

    Application.put_env(:fountain, :secret_expiry_notice_days, 0)

    user = insert_verified_user()
    vault = insert_vault(user_id: user.id)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(1, :day)
      |> DateTime.truncate(:second)

    insert_vault_secret(vault, key: "GH_TOKEN", expires_at: expires_at)

    assert :ok = perform_job(SecretExpirySweeper, %{})
    assert_no_email_sent()
  end
end
