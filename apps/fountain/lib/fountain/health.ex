defmodule Fountain.Health do
  @moduledoc """
  Dependency checks behind the readiness probe.

  The rule for what belongs here: a check earns its place only if a failure
  means this pod should stop receiving traffic. That is a higher bar than "is
  something wrong".

  * **Postgres** qualifies. Essentially every request touches it, so a pod that
    cannot reach it can serve nothing useful.

  * **Sprites does not.** An invalid or expired `SPRITES_TOKEN` breaks
    conversations while sign-in, the dashboard, agent and environment
    management all keep working. Failing readiness on it would take the whole
    site down over a degraded feature — and it would put a third party's uptime
    on our serving path, so their outage would become ours. It belongs in
    alerting, not in a probe.

  * **Migrations do not**, because they cannot fail here. `Ecto.Migrator` is a
    supervised child that runs before `FountainWeb.Endpoint` starts
    (`Fountain.Application`), so a pod that failed its migrations has no
    listening socket to probe — it crashes and restarts instead. A pending
    migration check would be code that can never fire.

  * **The egress broker listener qualifies**, wherever one is configured. It
    is a supervised child started *after* `FountainWeb.Endpoint`
    (`Fountain.Application`), so a fresh pod answers HTTP for a moment with
    nothing bound to `BROKER_LISTEN_PORT`. Every conversation of a deployment
    with a broker is brokered and none can fall back, so a provision routed
    into that window does not degrade — it fails outright with
    `:listener_down` (#1726). Neither exclusion above reaches it. The
    listener is our own in-process socket, not a third party's, so it puts
    nobody else's uptime on our serving path; and where a failed migration
    leaves no socket to probe, a late listener is the opposite case — the
    pod *is* listening and *is not* ready, which is the only shape a
    readiness probe can help with. The check is skipped where
    `BROKER_LISTEN_PORT` is unset, so a deployment with brokerage off keeps
    exactly the probe it had.

    One thing this check is honest about: it closes only the **starting**
    end. A pod whose
    listener stops while it drains cannot re-advertise itself unready in
    time; what closes that end is the listener's position in
    `Fountain.Application.children/0`, ahead of everything that can ask it to
    broker, and the two fixes landed together.
  """

  require Logger

  # A healthy check is ~2ms. These bound the unhealthy one as far as they can:
  # `:timeout` covers the query once a connection is in hand, and the queue
  # options cap how long we wait for the pool to produce one.
  #
  # They do not make the check fast when Postgres is unreachable. Measured
  # against a stopped Postgres, the endpoint answers 503 in ~2.9s: the connect
  # attempt and DBConnection's own retry are not per-call options, so some of
  # that wait is not ours to cap. The probe's `timeoutSeconds` (see
  # k8s/deployment.yaml) is the outer bound, set above that figure so kubelet
  # reads the explicit 503 rather than timing the request out — both score a
  # failure, but only one of them shows up as a real response.
  @check_opts [timeout: 2_000, queue_target: 200, queue_interval: 300]

  @doc """
  Round-trips a trivial query to Postgres.

  Returns `:ok` or `:error` — never a reason. The readiness endpoint is public
  (Traefik routes the whole host), so nothing here should describe our
  internals to an anonymous caller. The reason is logged instead.
  """
  @spec database(module()) :: :ok | :error
  def database(repo \\ Fountain.Repo) do
    case Ecto.Adapters.SQL.query(repo, "SELECT 1", [], @check_opts) do
      {:ok, _result} -> :ok
      {:error, reason} -> unhealthy("database", reason)
    end
  rescue
    # DBConnection raises when there is no connection to hand out at all.
    e -> unhealthy("database", e)
  catch
    # A pool checkout that gives up exits rather than returning.
    :exit, reason -> unhealthy("database", reason)
  end

  @doc """
  Is the egress broker listener up on this node?

  `:ok` where `BROKER_LISTEN_PORT` is unset: nothing listens, nothing is
  brokered, and there is no dependency to wait for. Otherwise this is
  `Fountain.Broker.preflight/0` — deliberately the *same* predicate a
  provision fails on, rather than a second opinion about the listener. A pod
  that would answer `:listener_down` to a provision answers 503 here, so the
  two can never disagree about whether this pod can broker.

  Returns `:ok` or `:error`, never a reason, for the reason `database/1`
  does; the detail is logged.

  `@check_opts` has no counterpart here because the predicate cannot block:
  `Managoat.Broker.running?/0` is a `Process.whereis/1` and a
  `Process.alive?/1`, microseconds with no socket and no pool behind them.
  This check therefore adds nothing to the probe's worst case, and the
  `timeoutSeconds` sized for a dead Postgres still covers it.

  The `rescue` and `catch` below bound a **raise or an exit, not slowness** —
  a raise here would render 500 from a public endpoint, which reads as a
  broken app rather than an unready one. They are not a substitute for a
  timeout. A backend that could block needs a real bound added here, and
  `@check_opts` is the shape it should take.
  """
  @spec broker_listener() :: :ok | :error
  def broker_listener do
    if Fountain.Broker.configured?() do
      case Fountain.Broker.preflight() do
        :ok -> :ok
        {:error, reason} -> unhealthy("broker listener", reason)
      end
    else
      :ok
    end
  rescue
    e -> unhealthy("broker listener", e)
  catch
    :exit, reason -> unhealthy("broker listener", reason)
  end

  defp unhealthy(check, reason) do
    Logger.warning("readiness: #{check} check failed: #{inspect(reason)}")
    :error
  end
end
