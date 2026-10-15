defmodule Fountain.AppsTest do
  @moduledoc """
  The one place that knows where the browser apps live (#866). Every link
  that leaves the console or a forwarded support report reads it from here,
  so they cannot drift apart.
  """

  use ExUnit.Case, async: false

  doctest Fountain.Apps

  alias Fountain.Apps

  setup do
    original = Application.fetch_env(:fountain, :conversations_app_url)

    on_exit(fn ->
      case original do
        {:ok, c} -> Application.put_env(:fountain, :conversations_app_url, c)
        :error -> Application.delete_env(:fountain, :conversations_app_url)
      end
    end)

    :ok
  end

  test "defaults to the hosted app" do
    Application.delete_env(:fountain, :conversations_app_url)

    assert Apps.conversations() == "https://fountain-conversations.demo.managoat.com/"
  end

  test "a configured URL wins, with exactly one trailing slash either way" do
    Application.put_env(:fountain, :conversations_app_url, "https://apps.example.com/convs")

    assert Apps.conversations() == "https://apps.example.com/convs/"
    assert Apps.conversation_url("c1") == "https://apps.example.com/convs/#/c/c1"
  end

  test "an empty string means this deployment has no such app" do
    Application.put_env(:fountain, :conversations_app_url, "")

    assert Apps.conversations() == nil
    assert Apps.conversation_url("c1") == nil
  end

  test "deep links follow the apps' own hash routes" do
    Application.put_env(:fountain, :conversations_app_url, "https://x.test/c/")

    assert Apps.conversation_url("abc") == "https://x.test/c/#/c/abc"
    assert Apps.conversation_url("abc", logs: true) == "https://x.test/c/#/c/abc/logs"
  end
end
