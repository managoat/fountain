defmodule FountainWeb.AdminSandboxResetRetryLiveTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.{Accounts, Audit, Quotas, Repo}

  setup %{conn: conn} do
    previous = Application.get_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, token: "test")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, previous),
        else: Application.delete_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    end)

    {:ok, admin} = insert_active_user() |> Accounts.update_user_role("admin")
    owner = insert_active_user()

    home =
      insert_sandbox(user_id: owner.id, status: "ready", mode: "persistent", provider: "sprites")
      |> Ecto.Changeset.change(reset_requested_at: DateTime.utc_now())
      |> Repo.update!()

    {:ok, lv, _html} = conn |> login_user(admin) |> live(~p"/admin/sandboxes")
    allow(Managoat.Sandbox, self(), lv.pid)
    {:ok, admin: admin, owner: owner, home: home, lv: lv}
  end

  test "a confirmed missing machine retires without another delete and audits the operator",
       ctx do
    expect(Managoat.Sandbox, :get, fn handle ->
      assert handle.name == ctx.home.machine_name
      refute Repo.in_transaction?()
      {:error, :not_found}
    end)

    reject(Managoat.Sandbox, :destroy, 1)
    assert retry(ctx) =~ "Provider confirmed deletion"
    assert_retired(ctx)
    assert_audit(ctx, "completed")

    # A repeated event cannot re-probe or publish another completion.
    reject(Managoat.Sandbox, :get, 1)
    assert render_click(ctx.lv, "retry_reset", %{"id" => ctx.home.id}) =~ "no longer"
    assert_audit(ctx, "skipped")
  end

  test "an existing machine gets a delete outside a transaction before capacity is released",
       ctx do
    expect(Managoat.Sandbox, :get, fn handle -> {:ok, handle} end)

    expect(Managoat.Sandbox, :destroy, fn handle ->
      assert handle.name == ctx.home.machine_name
      refute Repo.in_transaction?()
      assert Quotas.active_sandbox_count(ctx.owner.id) == 1
      assert Repo.reload!(ctx.home).reset_requested_at
      :ok
    end)

    assert retry(ctx) =~ "Provider confirmed deletion"
    assert_retired(ctx)
    assert_audit(ctx, "completed")
  end

  for failure <- [:probe, :delete] do
    test "an uncertain #{failure} preserves the fence and quota", ctx do
      case unquote(failure) do
        :probe ->
          expect(Managoat.Sandbox, :get, fn _ -> {:error, {:unavailable, :timeout}} end)
          reject(Managoat.Sandbox, :destroy, 1)

        :delete ->
          expect(Managoat.Sandbox, :get, fn handle -> {:ok, handle} end)
          expect(Managoat.Sandbox, :destroy, fn _ -> {:error, {:unavailable, :timeout}} end)
      end

      assert retry(ctx) =~ "Deletion is still unconfirmed"
      assert_fenced(ctx)
      assert_audit(ctx, "pending")
    end
  end

  for {change, to} <- [
        {:demotion, "/dashboard"},
        {:session, "/auth/login"},
        {:verification, "/auth/verify-pending"},
        {:suspension, "/auth/login"}
      ] do
    test "#{change} after mount blocks provider actions", ctx do
      attrs =
        case unquote(change) do
          :demotion -> [role: "user"]
          :session -> [session_version: ctx.admin.session_version + 1]
          :verification -> [email_verified_at: nil]
          :suspension -> [suspended_at: DateTime.truncate(DateTime.utc_now(), :second)]
        end

      ctx.admin |> Ecto.Changeset.change(attrs) |> Repo.update!()
      reject(Managoat.Sandbox, :get, 1)
      reject(Managoat.Sandbox, :destroy, 1)
      retry(ctx)
      assert_redirect(ctx.lv, unquote(to))
      assert_fenced(ctx)
      assert Audit._unsafe_list_recent_admin(10) == []
    end
  end

  test "unfenced, ineligible, missing and malformed rows never reach a provider", ctx do
    reject(Managoat.Sandbox, :get, 1)
    reject(Managoat.Sandbox, :destroy, 1)

    for attrs <- [
          [reset_requested_at: nil],
          [mode: "ephemeral"],
          [status: "pending"],
          [status: "starting"],
          [status: "terminated"]
        ] do
      ctx.home |> Ecto.Changeset.change(attrs) |> Repo.update!()
      assert render_click(ctx.lv, "retry_reset", %{"id" => ctx.home.id}) =~ "no longer"
      refute has_element?(ctx.lv, "button[phx-click=retry_reset]")

      ctx.home
      |> Repo.reload!()
      |> Ecto.Changeset.change(Map.take(ctx.home, [:mode, :status, :reset_requested_at]))
      |> Repo.update!()
    end

    for id <- [Ecto.UUID.generate(), "bad-id"] do
      assert render_click(ctx.lv, "retry_reset", %{"id" => id}) =~ "Sandbox not found"
    end
  end

  test "a disabled provider preserves the fence without attempting a probe", ctx do
    Application.delete_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    reject(Managoat.Sandbox, :get, 1)
    reject(Managoat.Sandbox, :destroy, 1)
    assert retry(ctx) =~ "Deletion is still unconfirmed"
    assert_fenced(ctx)
    assert_audit(ctx, "pending")
  end

  test "a retry the machine's owner is too busy for is a flash, not a lie", ctx do
    # ADR 0058 stage 5c. The row's lease is live, so another teardown of this
    # machine is running and the retry stands off before it probes or deletes.
    # The operator has to be able to tell that from the other two answers:
    # "skipped" would say the fence had cleared and "pending" would say the
    # provider had been asked and had not confirmed. Neither happened.
    ctx.home
    |> Ecto.Changeset.change(
      lease_epoch: 1,
      lease_node: "another@node",
      lease_until: DateTime.add(DateTime.utc_now(), 60, :second)
    )
    |> Repo.update!()

    reject(Managoat.Sandbox, :get, 1)
    reject(Managoat.Sandbox, :destroy, 1)
    assert retry(ctx) =~ "another teardown is running"
    assert_fenced(ctx)
    assert_audit(ctx, "busy")
  end

  test "a suspended pending reset can also be recovered", ctx do
    ctx.home |> Ecto.Changeset.change(status: "suspended") |> Repo.update!()
    send(ctx.lv.pid, :refresh)
    assert has_element?(ctx.lv, "button[phx-click=retry_reset]")
    expect(Managoat.Sandbox, :get, fn _ -> {:error, :not_found} end)
    reject(Managoat.Sandbox, :destroy, 1)
    retry(ctx)
    assert_retired(ctx)
  end

  defp retry(ctx) do
    ctx.lv
    |> element("button[phx-click=retry_reset][phx-value-id='#{ctx.home.id}']")
    |> render_click()
  end

  defp assert_fenced(ctx) do
    current = Repo.reload!(ctx.home)
    assert current.status == "ready"
    assert current.reset_requested_at == ctx.home.reset_requested_at
    refute current.terminated_at
    assert Quotas.active_sandbox_count(ctx.owner.id) == 1
  end

  defp assert_retired(ctx) do
    current = Repo.reload!(ctx.home)
    assert current.status == "terminated"
    assert current.terminated_at
    assert current.reset_requested_at == ctx.home.reset_requested_at
    assert Quotas.active_sandbox_count(ctx.owner.id) == 0
  end

  defp assert_audit(ctx, outcome) do
    assert Enum.any?(Audit._unsafe_list_recent_admin(10), fn event ->
             event.actor_user_id == ctx.admin.id and event.target_user_id == ctx.owner.id and
               event.event_type == "admin.sandbox.reset_retried" and
               event.metadata == %{"sandbox_id" => ctx.home.id, "outcome" => outcome}
           end)
  end
end
