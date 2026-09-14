defmodule FountainSupport do
  @moduledoc """
  Problem reports from users, filed from a client with the context the client
  had (#843). The report is stored, audited, and forwarded to the operator
  out of band — email to `SUPPORT_EMAIL`, a GitHub issue when
  `SUPPORT_GITHUB_REPO` + `SUPPORT_GITHUB_TOKEN` are set — by
  `FountainSupport.Workers.Forward`, so a slow or broken forwarder never
  fails the user's request.

  Tenant-scoped like everything else: a user sees only their own reports.
  The screenshot is bytes on the row (5 MB max), never in the audit trail
  or the forwarded mail body beyond "attached".

  The extension's context (ADR 0043, #1528). It was `Fountain.Support` until
  the move; the module name changed and nothing on the wire did. It consumes
  the host's public facilities — `Repo`, `Audit`, `Accounts`, `Mailer`,
  `Apps`, image decoding and the shared Oban — and owns every report-specific
  policy: the table, the validation, the audit metadata shape and where a
  report is forwarded.
  """
  import Ecto.Query

  alias Fountain.{Audit, Repo}
  alias FountainSupport.Report

  @doc """
  File a report. `attrs` is the API body: `category`, `message`, optional
  `context` (map), `client` (a client name/version), `screenshot`
  (`%{"data" => base64, "media_type" => ...}`). Audited as
  `support.report.created` (category, client, context keys, sizes — never
  the message). Enqueues the forwarder.
  """
  @spec create_report(binary(), map(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def create_report(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    with {:ok, shot} <- decode_screenshot(attrs["screenshot"]) do
      attrs =
        attrs
        |> Map.take(["category", "message", "context", "client"])
        |> Map.put("user_id", user_id)
        |> Map.merge(shot)

      %Report{}
      |> Report.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, report} ->
          record("support.report.created", report, opts, describe(report))
          enqueue_forward(report)
          {:ok, report}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "The caller's reports, newest first."
  @spec list_reports(binary()) :: [Report.t()]
  def list_reports(user_id) when is_binary(user_id) do
    Repo.all(from(r in Report, where: r.user_id == ^user_id, order_by: [desc: r.inserted_at]))
  end

  @spec get_report(binary(), binary()) :: Report.t() | nil
  def get_report(id, user_id) when is_binary(id) and is_binary(user_id) do
    Repo.get_by(Report, id: id, user_id: user_id)
  end

  @doc false
  def _unsafe_get_report(id) when is_binary(id), do: Repo.get(Report, id)

  @doc false
  def mark_forwarded(%Report{} = report, attrs) do
    report |> Report.forward_changeset(attrs) |> Repo.update()
  end

  @doc """
  Where reports go: the configured targets, for the forwarder and the docs.

  The two configurations sit under different otp_apps on purpose.
  `SUPPORT_GITHUB_REPO` / `SUPPORT_GITHUB_TOKEN` exist for this feature and
  nothing else, so they moved to `:fountain_support` with it (#1528).
  `SUPPORT_EMAIL` is the host's "contact support" address (#450): the account
  emails name it too, so it stays the host's key and this reads it the way any
  caller would. Moving it would have meant one env var
  writing two config keys, or core reading the extension's.
  """
  @spec targets() :: %{email: String.t() | nil, github: {String.t(), String.t()} | nil}
  def targets do
    email =
      case Application.get_env(:fountain, :support_email) do
        e when is_binary(e) and e != "" -> e
        _ -> nil
      end

    github =
      case {Application.get_env(:fountain_support, :support_github_repo),
            Application.get_env(:fountain_support, :support_github_token)} do
        {repo, token} when is_binary(repo) and repo != "" and is_binary(token) and token != "" ->
          {repo, token}

        _ ->
          nil
      end

    %{email: email, github: github}
  end

  defp enqueue_forward(%Report{id: id}) do
    %{"report_id" => id}
    |> FountainSupport.Workers.Forward.new()
    |> Oban.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("support report #{id}: could not enqueue forward: #{inspect(reason)}")
    end
  end

  defp decode_screenshot(nil), do: {:ok, %{}}

  defp decode_screenshot(%{} = shot) do
    case FountainWeb.PromptImages.decode([shot]) do
      {:ok, [%{media_type: mt, data: data}]} ->
        {:ok, %{"screenshot" => data, "screenshot_media_type" => mt}}

      {:error, msg} ->
        {:error, {:screenshot, msg}}
    end
  end

  defp decode_screenshot(_), do: {:error, {:screenshot, "screenshot must be an object"}}

  defp describe(%Report{} = r) do
    %{
      "category" => r.category,
      "client" => r.client,
      "message_bytes" => byte_size(r.message || ""),
      "context_keys" => r.context |> Map.keys() |> Enum.sort(),
      "screenshot" => is_binary(r.screenshot)
    }
  end

  defp record(action, %Report{} = report, opts, metadata) do
    Audit.record(%{
      user_id: report.user_id,
      action: action,
      resource_type: "support_report",
      resource_id: report.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: metadata
    })
  end
end
