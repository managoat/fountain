defmodule Fountain.ChatGPTUserGrantCeilingTest do
  # `config :fountain, :chatgpt_grant_ceiling` is application state.
  use Fountain.DataCase, async: false

  import Fountain.ChatGPTFixtures

  alias Fountain.Audit.Event
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.Grant
  alias Fountain.PlatformChatGPT.Account

  setup do
    previous = Application.fetch_env(:fountain, :chatgpt_grant_ceiling)
    Application.put_env(:fountain, :chatgpt_grant_ceiling, 2)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fountain, :chatgpt_grant_ceiling, value)
        :error -> Application.delete_env(:fountain, :chatgpt_grant_ceiling)
      end
    end)

    %{user: insert_verified_user(), platform: connect!(), shipped: previous}
  end

  test "the ceiling ships as five, and is five with nothing configured", ctx do
    assert ctx.shipped == {:ok, 5}
    Application.delete_env(:fountain, :chatgpt_grant_ceiling)
    assert ChatGPTAccounts.grant_ceiling() == 5
  end

  test "a third link is refused at a ceiling of two, with nothing written", ctx do
    assert {:ok, _} = link(ctx.user, "Personal", "acct-personal")
    assert {:ok, work} = link(ctx.user, "Work", "acct-work")
    events = grant_event_count(ctx.user)

    assert {:error, {:grant_limit_reached, %{count: 2, limit: 2}}} =
             link(ctx.user, "Side project", "acct-side")

    assert [%{name: "Personal"}, %{name: "Work"}] = ChatGPTAccounts.list_for_user(ctx.user.id)
    assert grant_event_count(ctx.user) == events

    # The ceiling is per account, and the platform grant is not under it.
    assert {:ok, _} = link(insert_verified_user(), "Work", "acct-work")

    # A reconnect is not a link.
    assert {:ok, _} =
             ChatGPTAccounts.reconnect_for_user(work.grant_id, ctx.user.id, tokens("acct-work"))

    assert Repo.get!(Account, ctx.platform.id) == ctx.platform
  end

  test "a disconnected grant holds its slot until it is removed", ctx do
    assert {:ok, _} = link(ctx.user, "Personal", "acct-personal")
    assert {:ok, work} = link(ctx.user, "Work", "acct-work")
    assert :ok = ChatGPTAccounts.disconnect_for_user(work.grant_id, ctx.user.id)

    assert {:error, {:grant_limit_reached, %{count: 2, limit: 2}}} =
             link(ctx.user, "Side project", "acct-side")

    assert :ok = ChatGPTAccounts.remove_for_user(work.grant_id, ctx.user.id)
    assert {:ok, %{name: "Side project"}} = link(ctx.user, "Side project", "acct-side")
    assert Repo.get!(Account, ctx.platform.id) == ctx.platform
  end

  test "lowering the ceiling under what an account holds refuses new links only", ctx do
    assert {:ok, personal} = link(ctx.user, "Personal", "acct-personal")
    assert {:ok, _} = link(ctx.user, "Work", "acct-work")
    Application.put_env(:fountain, :chatgpt_grant_ceiling, 1)

    assert {:error, {:grant_limit_reached, %{count: 2, limit: 1}}} =
             link(ctx.user, "Side project", "acct-side")

    assert {:ok, %Grant{}} =
             ChatGPTAccounts.credential_for_user(
               personal.grant_id,
               ctx.user.id,
               personal.generation
             )

    assert {:ok, %{name: "Home"}} =
             ChatGPTAccounts.rename_for_user(personal.grant_id, ctx.user.id, "Home")

    assert Repo.get!(Account, ctx.platform.id) == ctx.platform
  end

  defp grant_event_count(user) do
    Repo.aggregate(
      from(e in Event, where: e.user_id == ^user.id and like(e.action, "chatgpt_grant.%")),
      :count
    )
  end

  defp link(user, name, account_id),
    do: ChatGPTAccounts.connect_for_user(user.id, name, tokens(account_id))

  defp tokens(account_id) do
    %{
      access_token: access_token(),
      refresh_token: "rt_" <> account_id,
      id_token: id_token(%{account_id: account_id})
    }
  end
end
