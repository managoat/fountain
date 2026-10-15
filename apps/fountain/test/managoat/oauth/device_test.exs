defmodule Managoat.OAuth.DeviceTest do
  @moduledoc """
  The device-grant state machine, through `Fountain.OAuth`'s doors: polling
  pace, expiry, single use, decided-is-decided, and the two orderings (the
  subject is checked before the grant is consumed; a failed mint leaves it
  consumed). Carried over from the `managoat_oauth` library's suite when it
  was folded back (ADR 0037).
  """
  use Fountain.DataCase, async: true
  use Mimic

  import Ecto.Query

  alias Fountain.{Accounts, OAuth}
  alias Managoat.OAuth.{Device, DeviceGrant}

  @user_code ~r/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/

  defp grant_row(user_code) do
    Repo.get_by!(DeviceGrant, user_code: Device.normalize_user_code(user_code))
  end

  defp expire(user_code) do
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    code = Device.normalize_user_code(user_code)
    Repo.update_all(from(g in DeviceGrant, where: g.user_code == ^code), set: [expires_at: past])
  end

  test "user code generation does not consume the process PRNG state" do
    :rand.seed(:exsss, {17, 31, 53})
    seed = :rand.export_seed()

    for _ <- 1..32 do
      assert {:ok, %{user_code: user_code}} = OAuth.start_device_grant()
      assert user_code =~ @user_code
    end

    assert :rand.export_seed() == seed
  end

  test "start advertises fifteen minutes and a five-second interval" do
    assert {:ok, %{expires_in: 900, interval: 5, device_code: device_code}} =
             OAuth.start_device_grant()

    assert is_binary(device_code) and byte_size(device_code) > 20
  end

  test "the approval page finds a grant however the human typed it, and it is used once" do
    user = insert_verified_user()
    {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()

    assert {:ok, %DeviceGrant{subject_id: nil}} =
             OAuth.get_device_grant_for_approval(" " <> String.downcase(user_code) <> " ")

    assert :ok = OAuth.approve_device_grant(user_code, user.id)
    assert {:ok, %{api_key: %Accounts.ApiKey{}}} = OAuth.poll_device_grant(device_code)
    assert {:error, :invalid_grant} = OAuth.poll_device_grant(device_code)
  end

  test "polling faster than the interval gets slow_down" do
    {:ok, %{device_code: device_code}} = OAuth.start_device_grant()

    assert {:error, :authorization_pending} = OAuth.poll_device_grant(device_code)
    assert {:error, :slow_down} = OAuth.poll_device_grant(device_code)
  end

  test "decided is decided, in either direction" do
    user = insert_verified_user()
    {:ok, %{user_code: user_code}} = OAuth.start_device_grant()

    assert :ok = OAuth.deny_device_grant(user_code, user.id)
    assert {:error, :not_found} = OAuth.approve_device_grant(user_code, user.id)
    assert {:error, :not_found} = OAuth.deny_device_grant(user_code, user.id)
    assert {:error, :not_found} = OAuth.get_device_grant_for_approval(user_code)
  end

  test "an expired grant is expired_token to the poll and invisible to approval" do
    user = insert_verified_user()
    {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
    expire(user_code)

    assert {:error, :expired_token} = OAuth.poll_device_grant(device_code)
    assert {:error, :not_found} = OAuth.get_device_grant_for_approval(user_code)
    assert {:error, :not_found} = OAuth.approve_device_grant(user_code, user.id)
  end

  test "an unknown device code is invalid_grant" do
    assert {:error, :invalid_grant} = OAuth.poll_device_grant("not-a-code")
  end

  # The ordering rule, kept on purpose: the subject is checked before the
  # grant is consumed, so a refusal leaves it approved and pollable.
  test "a subject the host refuses gets access_denied and the grant is not consumed" do
    user = insert_user()
    {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
    assert :ok = OAuth.approve_device_grant(user_code, user.id)

    assert {:error, :access_denied} = OAuth.poll_device_grant(device_code)
    assert Accounts.list_api_keys(user.id) == []
    user_id = user.id

    assert %DeviceGrant{approved_at: %DateTime{}, used_at: nil, subject_id: ^user_id} =
             grant_row(user_code)

    # The state that changed can change back; the grant is still there.
    Repo.update_all(from(u in Fountain.Accounts.User, where: u.id == ^user.id),
      set: [email_verified_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    assert {:ok, %{api_key: %Accounts.ApiKey{user_id: ^user_id}}} =
             OAuth.poll_device_grant(device_code)
  end

  test "a mint that fails is :server_error, and the grant is consumed" do
    user = insert_verified_user()
    {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
    assert :ok = OAuth.approve_device_grant(user_code, user.id)

    stub(Accounts, :create_api_key, fn _user_id, _name, _opts -> {:error, :database_down} end)
    assert {:error, :server_error} = OAuth.poll_device_grant(device_code)
    assert %DeviceGrant{used_at: %DateTime{}} = grant_row(user_code)
    assert {:error, :invalid_grant} = OAuth.poll_device_grant(device_code)
  end

  test "an approved grant bound to no subject is refused as invalid_grant" do
    user = insert_verified_user()
    {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
    assert :ok = OAuth.approve_device_grant(user_code, user.id)

    # A row edited by hand: approval and subject are written in one update.
    code = Device.normalize_user_code(user_code)

    Repo.update_all(from(g in DeviceGrant, where: g.user_code == ^code),
      set: [subject_id: nil]
    )

    assert {:error, :invalid_grant} = OAuth.poll_device_grant(device_code)
  end

  test "normalize_user_code strips the display shape; format puts it back" do
    assert Device.normalize_user_code(" bcdf-ghjk ") == "BCDFGHJK"
    assert OAuth.format_user_code("BCDFGHJK") == "BCDF-GHJK"
    assert OAuth.format_user_code("odd") == "odd"
  end
end
