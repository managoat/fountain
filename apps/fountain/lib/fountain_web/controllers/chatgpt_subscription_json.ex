defmodule FountainWeb.ChatGPTSubscriptionJSON do
  @moduledoc false
  # What an owner may see of a subscription and of a sign-in, and nothing
  # else. Both functions name their keys one by one, so a field added to the
  # context's view is not published by being added: `account_id`,
  # `generation`, `lock_version` and `kind` are in the grant view and are not
  # here, and no token or ciphertext is in either view to begin with.

  alias Fountain.ChatGPTAccounts.AttemptView

  def index(%{grants: grants, limit: limit, linking_enabled: linking_enabled}) do
    %{
      data: Enum.map(grants, &grant_data/1),
      count: length(grants),
      limit: limit,
      linking_enabled: linking_enabled
    }
  end

  def show(%{grant: grant}), do: %{data: grant_data(grant)}

  def attempts(%{attempts: attempts}), do: %{data: Enum.map(attempts, &attempt_data/1)}
  def attempt(%{attempt: attempt}), do: %{data: attempt_data(attempt)}

  def grant_data(%{grant_id: id} = grant) do
    %{
      id: id,
      name: grant.name,
      status: grant.status,
      plan_type: grant.plan_type,
      account_email: grant.account_email,
      refreshable: grant.refreshable,
      access_expires_at: grant.access_expires_at,
      last_refreshed_at: grant.last_refreshed_at,
      revoked_reason: grant.revoked_reason,
      exhausted_until: grant.exhausted_until,
      inserted_at: grant.inserted_at,
      updated_at: grant.updated_at
    }
  end

  def attempt_data(%AttemptView{} = attempt) do
    %{
      id: attempt.id,
      kind: Atom.to_string(attempt.kind),
      name: attempt.name,
      grant_id: attempt.grant_id,
      state: attempt.state,
      user_code: attempt.user_code,
      verification_url: attempt.verification_url,
      poll_interval: attempt.poll_interval,
      expires_at: attempt.expires_at,
      result_grant_id: attempt.result_grant_id,
      failure: attempt.failure,
      inserted_at: attempt.inserted_at,
      updated_at: attempt.updated_at
    }
  end
end
