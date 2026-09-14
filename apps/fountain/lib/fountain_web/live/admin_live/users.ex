defmodule FountainWeb.AdminLive.Users do
  @moduledoc """
  `/admin/users` — the account list, and every operator lever that acts on one.

  Split out of `AdminLive.Index` when `/admin` stopped being one page. Nothing
  about the table changed: the filter, sort and page state still live in the
  URL so the ten-second refresh, an admin action and a browser reload all
  preserve position. What changed is that reading it no longer runs the funnel,
  the billing overview, the provider-spend attribution and the sandbox list
  alongside it, ten seconds apart, forever.

  Every lever here is confirmed at the button and recorded to the privilege
  trail (`/admin/activity`). The read-only money view is `/admin/finance`.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.{Accounts, Billing, Quotas}
  alias Fountain.Accounts.Deletion

  @usage_window_days 30
  @per_page 25
  @sorts ~w(email joined last_activity)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
     |> FountainWeb.Audited.put_client_ip()
     |> assign(:page_title, "Admin · Users")
     |> assign(:credits_enabled, Fountain.Credits.enabled?())
     |> assign(:extension_columns, [])}
  end

  # Filter/sort/page state lives in the URL, so the 10s refresh, admin
  # actions, and browser reloads all preserve position.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:filters, parse_filters(params))
     |> assign_users()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 10_000)
    {:noreply, assign_users(socket)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = %{
      socket.assigns.filters
      | search: params["q"] || "",
        comped: parse_yes_no(params["comped"]),
        role: if(params["role"] in ~w(admin user), do: params["role"]),
        verified: parse_yes_no(params["verified"]),
        page: 1
    }

    {:noreply, push_patch(socket, to: users_path(filters))}
  end

  @impl true
  def handle_event("toggle_admin", %{"id" => id}, socket) do
    with_target_user(socket, id, fn user -> do_toggle_admin(socket, user) end)
  end

  # The concurrency cap normally follows the tenant's balance (ADR 0031).
  # This overrides it, which is the lever for a noisy or abusive tenant
  # (ADR 0005) and the way to hand a trusted one more than their balance
  # funds. Submitting the field empty clears the override and hands the cap
  # back to the balance rule.
  @impl true
  def handle_event("set_sandbox_limit", %{"user_id" => id, "limit" => raw}, socket) do
    with {:ok, limit} <- parse_limit_override(raw),
         %Accounts.User{} = user <- Accounts.get_user(id),
         {:ok, _} <- Accounts.update_sandbox_limit(user, limit, actor: "admin") do
      Fountain.Audit.record_admin(%{
        actor_user_id: socket.assigns.current_user.id,
        target_user_id: user.id,
        event_type: "admin.sandbox_limit.changed",
        metadata: %{
          "email" => user.email,
          "from" => user.sandbox_limit_override,
          "to" => limit
        }
      })

      message =
        if is_nil(limit),
          do: "Override cleared — the cap follows the balance again",
          else: "Sandbox limit override set"

      {:noreply, socket |> assign_users() |> put_flash(:info, message)}
    else
      nil ->
        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:error, "User not found — the account may have been deleted")}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Override must be a whole number of 0 or more, or empty for the balance rule's cap"
         )}
    end
  end

  # The buttons are hidden when billing is disabled, but events can still be
  # sent by hand (#399's lesson) — and all of these actions talk to Stripe.
  @impl true
  def handle_event(event, _params, %{assigns: %{credits_enabled: false}} = socket)
      when event in ~w(toggle_comp) do
    {:noreply, put_flash(socket, :error, "Billing is disabled on this instance")}
  end

  @impl true
  def handle_event("toggle_comp", %{"id" => id}, socket) do
    with_target_user(socket, id, fn user -> do_toggle_comp(socket, user) end)
  end

  # The reversible abuse lever between comp and delete (#287): sessions die,
  # API keys refuse, sandboxes are reaped — and it all comes back with one
  # click. Billing is deliberately untouched; see Accounts.suspend_user/1.
  @impl true
  def handle_event("toggle_suspend", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    if id == admin.id do
      {:noreply, put_flash(socket, :error, "You cannot suspend your own account")}
    else
      with_target_user(socket, id, fn user -> do_toggle_suspend(socket, admin, user) end)
    end
  end

  # The support path for a deletion request that cannot go through the account
  # page — a locked-out user, or one who asked by email. Same teardown as
  # self-serve; only the actor recorded differs.
  @impl true
  def handle_event("delete_user", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    if id == admin.id do
      # The UI hides the button, but an event can still be sent by hand. An
      # admin deleting themselves mid-session is a support problem, not a
      # feature.
      {:noreply, put_flash(socket, :error, "Use your own account page to delete your account")}
    else
      with_target_user(socket, id, fn user -> do_delete_user(socket, admin, user) end)
    end
  end

  defp with_target_user(socket, id, fun) do
    case Accounts.get_user(id) do
      nil ->
        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:error, "User not found — the account may have been deleted")}

      user ->
        fun.(user)
    end
  end

  defp do_toggle_admin(socket, user) do
    new_role = if user.role == "admin", do: "user", else: "admin"

    case Accounts.update_user_role(user, new_role, actor: "admin") do
      {:ok, _} ->
        Fountain.Audit.record_admin(%{
          actor_user_id: socket.assigns.current_user.id,
          target_user_id: user.id,
          event_type:
            if(new_role == "admin", do: "admin.role.granted", else: "admin.role.revoked"),
          metadata: %{"email" => user.email, "from" => user.role, "to" => new_role}
        })

        {:noreply, socket |> assign_users() |> put_flash(:info, "Role updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update role")}
    end
  end

  defp do_toggle_comp(socket, user) do
    result =
      if user.comped,
        do: {Billing.revoke_comp(user), "admin.comp.revoked"},
        else: {Billing.comp_account(user), "admin.comp.granted"}

    case result do
      {{:ok, updated}, event_type} ->
        Fountain.Audit.record_admin(%{
          actor_user_id: socket.assigns.current_user.id,
          target_user_id: user.id,
          event_type: event_type,
          metadata: %{
            "email" => user.email,
            "from" => user.comped,
            "to" => updated.comped
          }
        })

        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:info, if(updated.comped, do: "Comped", else: "Comp revoked"))}

      {{:error, _}, _} ->
        {:noreply, put_flash(socket, :error, "Could not change comp")}
    end
  end

  defp do_toggle_suspend(socket, admin, user) do
    if Accounts.suspended?(user) do
      case Accounts.unsuspend_user(user, actor: "admin") do
        {:ok, _} ->
          Fountain.Audit.record_admin(%{
            actor_user_id: admin.id,
            target_user_id: user.id,
            event_type: "admin.account.unsuspended",
            metadata: %{"email" => user.email}
          })

          {:noreply, socket |> assign_users() |> put_flash(:info, "Suspension lifted")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not lift the suspension")}
      end
    else
      case Accounts.suspend_user(user, actor: "admin") do
        {:ok, _, reaped} ->
          Fountain.Audit.record_admin(%{
            actor_user_id: admin.id,
            target_user_id: user.id,
            event_type: "admin.account.suspended",
            metadata: %{"email" => user.email, "sandboxes_reaped" => reaped}
          })

          {:noreply,
           socket
           |> assign_users()
           |> put_flash(:info, "Suspended — #{reaped} sandbox(es) reaped")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not suspend the account")}
      end
    end
  end

  defp do_delete_user(socket, admin, user) do
    case Deletion.delete_user(user,
           actor: "admin:#{admin.id}",
           request_ip: socket.assigns[:client_ip]
         ) do
      {:ok, _summary} ->
        Fountain.Audit.record_admin(%{
          actor_user_id: admin.id,
          target_user_id: user.id,
          event_type: "admin.account.deleted",
          metadata: %{"email" => user.email}
        })

        {:noreply, socket |> assign_users() |> put_flash(:info, "Deleted #{user.email}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Deletion failed — nothing was deleted")}
    end
  end

  # "" clears the override (the cap goes back to the balance rule); anything else
  # must be a whole number of zero or more.
  defp parse_limit_override(raw) do
    case String.trim(raw) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {limit, ""} when limit >= 0 -> {:ok, limit}
          _ -> :error
        end
    end
  end

  defp assign_users(socket) do
    f = socket.assigns.filters
    now = DateTime.utc_now()

    # Upper bound one second ahead: the column is second-precision, so a bound
    # of `now` loses its sub-second part in the cast and excludes events
    # recorded within the current second.
    usage =
      Billing.usage_summaries(
        DateTime.add(now, -@usage_window_days, :day),
        DateTime.add(now, 1, :second)
      )

    no_usage = %{
      conversations: 0,
      turns: 0,
      sandbox_minutes: 0.0,
      sandbox_minutes_by_provider: %{},
      turn_hours: 0.0
    }

    sandbox_counts = Quotas.active_sandbox_counts()
    # Whatever installed extensions add (ADR 0043). Each is one grouped query
    # built once for the page, same contract as the counts above; the console
    # names no extension module. A hosted Buzz agent is a standing OS process
    # that no sandbox meter reports (#1017), which is why an extension gets to
    # put a number on the row at all.
    extension_columns = Fountain.Extensions.admin_user_columns()

    %{users: users, total: total} =
      Accounts.list_users_admin(
        search: f.search,
        comped: f.comped,
        role: f.role,
        verified: f.verified,
        sort: f.sort,
        dir: f.dir,
        page: f.page,
        per_page: @per_page
      )

    users =
      Enum.map(users, fn u ->
        u
        |> Map.put(:active_sandboxes, Map.get(sandbox_counts, u.id, 0))
        |> Map.put(:sandbox_limit, Fountain.Quotas.sandbox_limit_for(u))
        |> Map.put(
          :extension_cells,
          Enum.map(extension_columns, fn {_header, cells} -> Map.get(cells, u.id, 0) end)
        )
        |> Map.put(:usage, Map.get(usage, u.id, no_usage))
      end)

    socket
    |> assign(:users, users)
    |> assign(:extension_columns, extension_columns)
    |> assign(:total_users, total)
  end

  # One extension-contributed number. A bare value, or
  # `%{value: v, alert?: true}` when the extension wants it highlighted — its
  # ceiling, its policy; the host owns the colour.
  attr :cell, :any, required: true

  defp extension_cell(assigns) do
    {value, alert?} = normalize_cell(assigns.cell)
    assigns = assigns |> assign(:value, value) |> assign(:alert?, alert?)

    ~H"""
    <td class="px-4 py-2 text-xs text-zinc-500 tabular-nums whitespace-nowrap">
      <span class={if(@alert?, do: "text-red-600 font-medium", else: "")}>{@value}</span>
    </td>
    """
  end

  defp normalize_cell(%{value: value} = cell), do: {value, Map.get(cell, :alert?, false)}
  defp normalize_cell(value), do: {value, false}

  defp parse_filters(params) do
    %{
      search: params["q"] || "",
      comped: parse_yes_no(params["comped"]),
      role: if(params["role"] in ~w(admin user), do: params["role"]),
      verified: parse_yes_no(params["verified"]),
      sort: if(params["sort"] in @sorts, do: params["sort"], else: "joined"),
      dir: if(params["dir"] in ~w(asc desc), do: params["dir"], else: "desc"),
      page: parse_page(params["page"])
    }
  end

  defp parse_yes_no("yes"), do: true
  defp parse_yes_no("no"), do: false
  defp parse_yes_no(_), do: nil

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
  defp yes_no(_), do: nil

  defp parse_page(raw) do
    case is_binary(raw) && Integer.parse(raw) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  @doc """
  `/admin/users` carrying `filters` as query params.

  Public because the pages that link *into* a filtered list build the same
  URL — the finance page, the overview's "funded accounts"
  tile — and a second hand-rolled copy of this would drift.
  """
  def users_path(f) do
    params =
      [
        q: if(f[:search] not in [nil, ""], do: f[:search]),
        comped: yes_no(f[:comped]),
        role: f[:role],
        verified: yes_no(f[:verified]),
        sort: if(f[:sort] && f[:sort] != "joined", do: f[:sort]),
        dir: if(f[:dir] && f[:dir] != "desc", do: f[:dir]),
        page: if(f[:page] && f[:page] > 1, do: f[:page])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    ~p"/admin/users?#{params}"
  end

  defp sort_toggle(f, col) do
    cond do
      f.sort == col -> %{f | dir: flip(f.dir), page: 1}
      col == "email" -> %{f | sort: col, dir: "asc", page: 1}
      true -> %{f | sort: col, dir: "desc", page: 1}
    end
  end

  defp flip("asc"), do: "desc"
  defp flip(_), do: "asc"

  defp page_count(total), do: max(div(total + @per_page - 1, @per_page), 1)

  attr :label, :string, required: true
  attr :col, :string, required: true
  attr :filters, :map, required: true

  defp sort_header(assigns) do
    ~H"""
    <.link patch={users_path(sort_toggle(@filters, @col))} class="hover:text-zinc-900">
      {@label}
      <span :if={@filters.sort == @col} class="text-zinc-400">
        {if @filters.dir == "asc", do: "↑", else: "↓"}
      </span>
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Users" current={:users} credits_enabled={@credits_enabled}>
        <:subtitle>
          {@total_users} {if @total_users == 1, do: "account", else: "accounts"}. Refreshes every 10s.
        </:subtitle>
      </.admin_header>

      <section class="space-y-3">
        <form phx-change="filter" id="user-filters" class="flex flex-wrap items-center gap-2">
          <input
            type="text"
            name="q"
            value={@filters.search}
            placeholder="Search email…"
            phx-debounce="300"
            autocomplete="off"
            class="w-48 rounded border border-zinc-200 px-2 py-1 text-xs"
          />
          <select
            :if={@credits_enabled}
            name="comped"
            class="rounded border border-zinc-200 px-1 py-1 text-xs"
          >
            <option value="">comped or billed</option>
            <option value="yes" selected={@filters.comped == true}>comped</option>
            <option value="no" selected={@filters.comped == false}>billed</option>
          </select>
          <select name="role" class="rounded border border-zinc-200 px-1 py-1 text-xs">
            <option value="">any role</option>
            <option value="admin" selected={@filters.role == "admin"}>admin</option>
            <option value="user" selected={@filters.role == "user"}>user</option>
          </select>
          <select name="verified" class="rounded border border-zinc-200 px-1 py-1 text-xs">
            <option value="">any verification</option>
            <option value="yes" selected={@filters.verified == true}>verified</option>
            <option value="no" selected={@filters.verified == false}>unverified</option>
          </select>
        </form>

        <table class="w-full text-sm bg-white rounded shadow border border-zinc-200">
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">
                <.sort_header label="Email" col="email" filters={@filters} />
              </th>
              <th class="px-4 py-2">Role</th>
              <th :if={@credits_enabled} class="px-4 py-2">
                Billing
              </th>
              <th
                :if={@credits_enabled}
                class="px-4 py-2"
                title="The balance, or comped: an operator made this account free"
              >
                Credit
              </th>
              <th
                class="px-4 py-2"
                title="Last 30 days: conversations · turns · turn hours (the unit credit is burned in)"
              >
                Usage 30d
              </th>
              <th class="px-4 py-2">Sandboxes</th>
              <%!-- Standing slots: an installed extension may add a column of
                    its own here (#1017's hosted-agent count is one of those),
                    for a thing that costs while nobody uses it. --%>
              <th :for={{header, _cells} <- @extension_columns} class="px-4 py-2">{header}</th>
              <th class="px-4 py-2">Onboarding</th>
              <th class="px-4 py-2">
                <.sort_header label="Last active" col="last_activity" filters={@filters} />
              </th>
              <th class="px-4 py-2">
                <.sort_header label="Joined" col="joined" filters={@filters} />
              </th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@users == []}>
              <td
                colspan={if @credits_enabled, do: "10", else: "8"}
                class="px-4 py-6 text-center text-sm text-zinc-500"
              >
                No users match.
              </td>
            </tr>
            <tr :for={u <- @users} class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
              <td class="px-4 py-2 font-mono text-xs">
                <.link navigate={~p"/admin/users/#{u.id}"} class="hover:underline">
                  {u.email}
                </.link>
                <span
                  :if={is_nil(u.email_verified_at)}
                  class="ml-1 inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border bg-zinc-100 text-zinc-500 border-zinc-200"
                >
                  unverified
                </span>
                <span
                  :if={u.suspended_at}
                  class="ml-1 inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border bg-red-100 text-red-700 border-red-200"
                  title={"since #{format_ts(u.suspended_at)}"}
                >
                  suspended
                </span>
              </td>
              <td class="px-4 py-2">
                <span class={[
                  "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                  if(u.role == "admin",
                    do: "bg-amber-100 text-amber-800 border-amber-200",
                    else: "bg-zinc-100 text-zinc-600 border-zinc-200"
                  )
                ]}>
                  {u.role}
                </span>
              </td>
              <td :if={@credits_enabled} class="px-4 py-2">
                <div class="flex flex-col gap-1">
                  <span class={[
                    "inline-flex w-fit items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                    account_badge_class(u.comped)
                  ]}>
                    {if u.comped,
                      do: "comped",
                      else: Fountain.Credits.format_cents(u.credit_balance_cents)}
                  </span>
                  <button
                    phx-click="toggle_comp"
                    phx-value-id={u.id}
                    data-confirm={
                      if u.comped,
                        do:
                          "Revoke #{u.email}'s comp? Their balance is checked again from the next spend.",
                        else:
                          "Comp #{u.email}? Their balance is never checked and nothing is refused."
                    }
                    class="text-xs text-zinc-500 hover:text-zinc-900 underline text-left"
                  >
                    {if u.comped, do: "revoke comp", else: "comp"}
                  </button>
                </div>
              </td>
              <%!-- Turn hours, not sandbox minutes. Sandbox time is what
                    Fountain is billed and it is on /admin/finance; what a
                    tenant *buys* is turn hours (ADR 0031), so that is the
                    number to read beside their balance. The tooltip keeps
                    the sandbox side one hover away. --%>
              <td
                class="px-4 py-2 text-xs text-zinc-500 tabular-nums whitespace-nowrap"
                title={usage_tooltip(u.usage)}
              >
                {u.usage.conversations}c · {u.usage.turns}t · {format_hours(u.usage.turn_hours)}
              </td>
              <td class="px-4 py-2">
                <form
                  phx-submit="set_sandbox_limit"
                  id={"sandbox-limit-#{u.id}"}
                  class="flex items-center gap-1"
                >
                  <input type="hidden" name="user_id" value={u.id} />
                  <span class={[
                    "text-xs tabular-nums",
                    if(u.active_sandboxes >= u.sandbox_limit,
                      do: "text-red-600 font-medium",
                      else: "text-zinc-500"
                    )
                  ]}>
                    {u.active_sandboxes} / {u.sandbox_limit}
                  </span>
                  <%!-- Empty means "no override": the cap is the balance rule's, shown
                        as the placeholder so an admin can see what clearing
                        the box would leave behind. --%>
                  <input
                    type="number"
                    name="limit"
                    min="0"
                    value={u.sandbox_limit_override}
                    placeholder={u.sandbox_limit}
                    title="Empty: what the balance funds (ADR 0031)"
                    class="w-14 rounded border border-zinc-200 px-1 py-0.5 text-xs"
                  />
                  <button class="text-xs text-zinc-500 hover:text-zinc-900 underline">set</button>
                </form>
              </td>
              <.extension_cell :for={cell <- u.extension_cells} cell={cell} />
              <td class="px-4 py-2 text-zinc-500 text-xs">
                {if u.onboarding_completed_at, do: format_date(u.onboarding_completed_at), else: "—"}
              </td>
              <td class="px-4 py-2 text-zinc-500 text-xs">
                {if u.last_activity_at, do: format_date(u.last_activity_at), else: "—"}
              </td>
              <td class="px-4 py-2 text-zinc-500 text-xs">{format_date(u.inserted_at)}</td>
              <td class="px-4 py-2 text-right space-x-3">
                <button
                  phx-click="toggle_admin"
                  phx-value-id={u.id}
                  data-confirm={"Toggle admin for #{u.email}?"}
                  class="text-xs text-zinc-600 hover:text-zinc-900 underline"
                >
                  {if u.role == "admin", do: "Remove admin", else: "Make admin"}
                </button>
                <button
                  :if={u.id != @current_user.id}
                  phx-click="toggle_suspend"
                  phx-value-id={u.id}
                  data-confirm={
                    if u.suspended_at,
                      do: "Lift #{u.email}'s suspension? They can log in again immediately.",
                      else:
                        "Suspend #{u.email}? Sessions and API keys stop working and running conversations are terminated. Reversible; billing is not touched."
                  }
                  class="text-xs text-amber-700 hover:text-amber-900 underline"
                >
                  {if u.suspended_at, do: "Unsuspend", else: "Suspend"}
                </button>
                <button
                  :if={u.id != @current_user.id}
                  phx-click="delete_user"
                  phx-value-id={u.id}
                  data-confirm={"Permanently delete #{u.email}? This destroys their sandboxes and erases their data. It cannot be undone."}
                  class="text-xs text-red-600 hover:text-red-800 underline"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <div
          :if={page_count(@total_users) > 1 or @filters.page > 1}
          class="flex items-center justify-between text-xs text-zinc-500"
        >
          <span>Page {@filters.page} of {page_count(@total_users)}</span>
          <div class="space-x-3">
            <.link
              :if={@filters.page > 1}
              patch={users_path(%{@filters | page: @filters.page - 1})}
              class="underline"
            >
              ← prev
            </.link>
            <.link
              :if={@filters.page < page_count(@total_users)}
              patch={users_path(%{@filters | page: @filters.page + 1})}
              class="underline"
            >
              next →
            </.link>
          </div>
        </div>
      </section>
    </div>
    """
  end

  # The sandbox side of the usage cell, which the cell itself no longer shows:
  # total active time and which provider it ran on. Nil when the tenant had no
  # sandbox time, so the attribute renders as nothing rather than as an empty
  # tooltip.
  defp usage_tooltip(%{sandbox_minutes_by_provider: by_provider}) when map_size(by_provider) == 0,
    do: nil

  defp usage_tooltip(usage) do
    split =
      usage.sandbox_minutes_by_provider
      |> Enum.sort()
      |> Enum.map_join(" · ", fn {provider, minutes} -> "#{provider} #{round(minutes)}m" end)

    "#{round(usage.sandbox_minutes)}m sandbox time (#{split}) — what we are billed, on /admin/finance"
  end
end
