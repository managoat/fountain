defmodule Fountain.Conversations.SandboxURLTest do
  @moduledoc """
  An agent asked "what is your URL?" has to be able to answer.

  It cannot work it out from inside: the platform assigns the endpoint outside
  the sandbox, and in there the hostname is just `sprite`. So the URL has to
  arrive as environment, and it has to be stored where the API can show it
  without a provider round trip.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Managoat.Sandbox

  setup do
    Managoat.Sandbox.Fake.reset()
    user = insert_verified_user()
    {:ok, user: user}
  end

  describe "the provider contract" do
    # The Fake is not in the configured provider list (it is a test double, not
    # a deployment target), so this goes through the adapter directly — the
    # facade's dispatch is covered by the providers below.
    test "an adapter that advertises :public_url reports one" do
      alias Managoat.Sandbox.Fake

      name = "url-test-#{System.unique_integer([:positive])}"
      {:ok, handle} = Fake.create(name, [])

      assert MapSet.member?(Fake.capabilities(), :public_url)
      assert {:ok, "https://url-test-" <> _} = Fake.public_url(handle)
    end

    # The two providers that expose per-port hostnames rather than one sandbox
    # URL say so, instead of returning something that looks like an address.
    test "e2b and daytona report :unsupported rather than guessing" do
      for provider <- [:e2b, :daytona] do
        handle = Sandbox.build_handle(provider, "whatever")

        refute Sandbox.supports?(provider, :public_url)
        assert {:error, :unsupported} = Sandbox.public_url(handle)
      end
    end
  end

  describe "the sandbox row" do
    test "carries the URL so the API can show it without asking the provider", %{user: user} do
      sandbox = insert_sandbox(user_id: user.id)

      {:ok, updated} =
        update_sandbox(sandbox, %{
          provider_meta: Map.put(sandbox.provider_meta || %{}, "public_url", "https://x.example")
        })

      assert updated.provider_meta["public_url"] == "https://x.example"
    end

    # A sandbox that predates the field, or one on a provider with no URL, must
    # render as null rather than blowing up the serializer.
    test "renders as null when there is none", %{user: user} do
      sandbox = insert_sandbox(user_id: user.id)
      conv = insert_conversation(user_id: user.id, sandbox_id: sandbox.id)

      rendered =
        FountainWeb.ConversationJSON.show(%{
          conversation: Fountain.Repo.preload(conv, :sandbox)
        })

      assert rendered.data.sandbox.url == nil
    end

    test "renders the URL when the row has one", %{user: user} do
      sandbox = insert_sandbox(user_id: user.id)

      {:ok, _} =
        update_sandbox(sandbox, %{
          provider_meta: %{"public_url" => "https://y.test"}
        })

      conv = insert_conversation(user_id: user.id, sandbox_id: sandbox.id)

      rendered =
        FountainWeb.ConversationJSON.show(%{
          conversation: Fountain.Repo.preload(conv, :sandbox)
        })

      assert rendered.data.sandbox.url == "https://y.test"
    end
  end
end
