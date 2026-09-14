defmodule Fountain.Billing.ReconciliationTest do
  @moduledoc """
  Computed against invoiced (#1038 step 1) and the dropped-events count
  (step 2). `async: false`: the rate card is global config.
  """

  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.Audit
  alias Fountain.Billing
  alias Fountain.Billing.Finance
  alias Fountain.Billing.Reconciliation
  alias Fountain.Repo

  @rate_keys ~w(provider_hourly_cents)a

  setup do
    original = Map.new(@rate_keys, &{&1, Application.get_env(:fountain, &1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:fountain, key)
        {key, value} -> Application.put_env(:fountain, key, value)
      end)
    end)

    Enum.each(@rate_keys, &Application.delete_env(:fountain, &1))
    Reconciliation.reset_drop_counter()
    :ok
  end

  defp insert_admin do
    {:ok, admin} = Accounts.update_user_role(insert_verified_user(), "admin")
    admin
  end

  # The previous, closed month: the page and Finance.summary clip every
  # interval to `now`, so hours seeded forward from the running month's start
  # only report in full once the month is that many hours old — these tests
  # failed on the first CI runs of 2026-09-01, the same way
  # admin_finance_live_test.exs did. A closed month has a fixed ceiling, so
  # the numbers are exact whenever the suite runs. Tests that seed through
  # `ran/2` compute over `month_range(1)` and open the page with
  # ?months_ago=1.
  defp month_start, do: Billing.month_range(1).start

  defp ran(user, hours) do
    started = month_start()

    insert_sandbox(
      user_id: user.id,
      provider: "sprites",
      status: "terminated",
      inserted_at: started,
      terminated_at: DateTime.add(started, hours * 3600, :second)
    )
  end

  test "record_invoice upserts per provider and month, and audits without a tenant" do
    attrs = %{
      "provider" => "sprites",
      "period_start" => ~D[2026-07-01],
      "period_end" => ~D[2026-07-31],
      "amount_cents" => 12_345,
      "note" => "inv_1"
    }

    assert {:ok, first} = Reconciliation.record_invoice(attrs, actor: "admin:x")

    assert {:ok, second} =
             Reconciliation.record_invoice(%{attrs | "amount_cents" => 20_000}, actor: "admin:x")

    assert first.id == second.id
    assert Reconciliation.invoices_for(~D[2026-07-01])["sprites"].amount_cents == 20_000
    assert Reconciliation.invoices_for(~D[2026-06-01]) == %{}

    assert {:error, %Ecto.Changeset{}} =
             Reconciliation.record_invoice(%{attrs | "provider" => "aws"})

    events = Repo.all(Audit.Event) |> Enum.filter(&(&1.action == "finance.invoice.recorded"))
    assert length(events) == 2
    assert Enum.all?(events, &(is_nil(&1.user_id) and &1.actor == "admin:x"))
    assert hd(events).metadata["amount_cents"] in [12_345, 20_000]
  end

  test "lines: computed per provider at the rate card, delta against the invoice, nil where unpriced" do
    Application.put_env(:fountain, :provider_hourly_cents, %{"sprites" => 100})
    user = insert_verified_user()
    ran(user, 10)

    %{start: ps, end: pe} = Billing.month_range(1)
    summary = Finance.summary(period: {ps, pe}, basis: :active)

    {:ok, _} =
      Reconciliation.record_invoice(%{
        "provider" => "sprites",
        "period_start" => DateTime.to_date(ps),
        "period_end" => DateTime.to_date(pe),
        "amount_cents" => 1_100
      })

    lines = Reconciliation.lines(summary, Reconciliation.invoices_for(DateTime.to_date(ps)))
    by = Map.new(lines, &{&1.provider, &1})

    assert by["sprites"].computed_cents == 1_000
    assert by["sprites"].recorded_cents == 1_100
    assert by["sprites"].delta_cents == 100
    # No e2b hours and no e2b rate: nothing to compute.
    assert by["e2b"].computed_cents == nil
    assert by["e2b"].recorded_cents == nil and by["e2b"].delta_cents == nil
    assert Enum.map(lines, & &1.provider) == ~w(sprites e2b daytona)
  end

  test "the panel shows the lines, records an invoice from the form, and surfaces dropped events",
       %{conn: conn} do
    Application.put_env(:fountain, :provider_hourly_cents, %{"sprites" => 100})
    admin = insert_admin()
    ran(insert_verified_user(), 10)

    {:ok, lv, html} = live(login_user(conn, admin), ~p"/admin/finance?months_ago=1")
    assert html =~ "Provider invoices"
    assert html =~ "$10.00"
    refute html =~ "dropped on this node"

    html =
      render_submit(lv, "record_invoice", %{
        "provider" => "sprites",
        "amount" => "$12.50",
        "note" => "inv_9"
      })

    assert html =~ "$12.50"
    assert html =~ "$2.50"
    assert html =~ "inv_9"

    html = render_submit(lv, "record_invoice", %{"provider" => "sprites", "amount" => "lots"})
    assert html =~ "Enter the invoice total in dollars"

    :telemetry.execute([:fountain, :usage, :dropped], %{count: 3}, %{event_type: "x", kind: "y"})
    assert Reconciliation.dropped_on_this_node() == 3
    {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/finance")
    assert html =~ "3 metering events dropped on this node"
  end
end
