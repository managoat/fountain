defmodule Fountain.Conversations.OpeningInputTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, ConversationServer, PromptInput, Sandbox}
  alias Fountain.Conversations.Launch

  setup do
    user = insert_active_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        agent_id: agent.id,
        environment_id: env.id
      )

    {:ok, user: user, agent: agent, sandbox: sandbox}
  end

  for path <- [:create, :attach] do
    @tag path: path
    test "#{path} refuses invalid text before allocating rows or starting work", ctx do
      reject_server_start()
      reject(ConversationServer, :send_prompt, 4)
      counts = row_counts()

      for prompt <- [" ", "\n\t", 123, ["hello"]] do
        assert {:error, :invalid_prompt} = start(ctx, %{"prompt" => prompt})
        assert row_counts() == counts
      end
    end

    @tag path: path
    test "#{path} refuses images without opening text", ctx do
      reject_server_start()
      reject(ConversationServer, :send_prompt, 4)
      counts = row_counts()
      image = %{media_type: "image/png", data: <<1>>}

      for prompt <- [nil, ""] do
        assert {:error, :invalid_prompt} = start(ctx, %{"prompt" => prompt, "images" => [image]})
        assert row_counts() == counts
      end
    end

    @tag path: path
    test "#{path} rejects malformed, empty, unsupported and oversized image bytes", ctx do
      reject_server_start()
      reject(ConversationServer, :send_prompt, 4)
      counts = row_counts()
      large = :binary.copy(<<0>>, Fountain.Images.max_prompt_image_bytes() + 1)

      for image <- [
            %{},
            %{media_type: "image/png", data: ""},
            %{media_type: "text/html", data: "html"},
            %{media_type: "image/png", data: large}
          ] do
        assert {:error, :invalid_images} =
                 start(ctx, %{"prompt" => "Review", "images" => [image]})

        assert row_counts() == counts
      end
    end

    @tag path: path
    test "#{path} still accepts a launch without an opening prompt", ctx do
      stub_server_start(fn _, _ -> {:ok, self()} end)
      assert {:ok, _} = start(ctx, %{})
    end

    @tag path: path
    test "#{path} passes valid opening text and image bytes to delivery", ctx do
      image = %{media_type: "image/png", data: <<0, 1, 2>>}

      case ctx.path do
        :create ->
          expect_server_start(fn _, _ -> {:ok, self()} end)

        :attach ->
          expect(ConversationServer, :send_prompt, fn _, "Review", [^image], _ -> :ok end)
      end

      assert {:ok, _} = start(ctx, %{"prompt" => "Review", "images" => [image]})

      if ctx.path == :create,
        do: assert_received({:"$gen_cast", {:initial_prompt, "Review", [^image]}})
    end
  end

  # `attrs["images"]` is the decoded shape. Each refusal is paired with the
  # accept, so the pair only passes when the map is actually read rather than
  # rejected wholesale.
  test "only the decoded shape is accepted" do
    good = %{media_type: "image/png", data: <<0, 1, 2>>}

    for bad <- [
          %{good | media_type: "text/html"},
          %{good | data: ""},
          Map.delete(good, :data),
          Map.delete(good, :media_type),
          %{good | data: :binary.copy(<<0>>, Fountain.Images.max_prompt_image_bytes() + 1)},
          # Not the decoded shape: `PromptImages.decode/1` returns atom keys,
          # and the three consumers below pattern-match them.
          %{"media_type" => "image/png", "data" => <<0, 1, 2>>},
          %URI{}
        ] do
      assert {:error, :invalid_images} =
               PromptInput.validate_initial(%{"prompt" => "Review", "images" => [bad]})

      assert :ok = PromptInput.validate_initial(%{"prompt" => "Review", "images" => [good]})
    end
  end

  # The gap the mocked delivery test leaves: `validate_initial/1` saying `:ok`
  # is only worth anything if the shape it accepts survives the consumers that
  # run after a sandbox has been paid for. `store_images/2` sits in
  # `run_turn/6` before sending the ACP prompt and turns an `{:error, changeset}` into
  # a log line, but a key it cannot match raises out of the server instead.
  test "the accepted shape survives image storage after provisioning", ctx do
    image = %{media_type: "image/png", data: <<0, 1, 2>>}
    assert :ok = PromptInput.validate_initial(%{"prompt" => "Review", "images" => [image]})

    conv = insert_conversation(user_id: ctx.user.id, agent: ctx.agent)

    # A turn each: `store_images/2` swallows a duplicate-position changeset
    # error by design, so sharing one would hide whether it read the map.
    [direct, stored] =
      for n <- 1..2 do
        {:ok, turn} =
          Conversations._unsafe_create_turn(%{
            conversation_id: conv.id,
            turn_number: n,
            status: "running",
            prompt: "Review"
          })

        turn
      end

    assert {:ok, 1} = Conversations._unsafe_insert_turn_images(direct.id, [image])
    assert :ok = Fountain.Conversations.TurnMachine.store_images(stored, [image])

    for turn <- [direct, stored] do
      assert %{images: [%{media_type: "image/png", data: <<0, 1, 2>>}]} =
               Repo.preload(turn, :images)
    end
  end

  @tag path: :attach
  test "the decoded shape reaches delivery unchanged", ctx do
    image = %{media_type: "image/png", data: <<0, 1, 2>>}
    expect(ConversationServer, :send_prompt, fn _, "Review", [^image], _ -> :ok end)
    assert {:ok, _} = start(ctx, %{"prompt" => "Review", "images" => [image]})
  end

  defp start(ctx, extra) do
    attrs = %{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id}
    attrs = if ctx.path == :attach, do: Map.put(attrs, "sandbox_id", ctx.sandbox.id), else: attrs
    Launch.start_conversation(Map.merge(attrs, extra))
  end

  defp row_counts, do: {Repo.aggregate(Conversation, :count), Repo.aggregate(Sandbox, :count)}
end
