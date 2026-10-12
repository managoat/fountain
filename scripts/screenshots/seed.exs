# Run only against the disposable screenshot database, never a development or hosted database.
unless Mix.env() == :test and
         URI.parse(System.fetch_env!("DATABASE_URL")).path == "/fountain_capture_burndown" do
  raise "Use MIX_ENV=test and DATABASE_URL ending in /fountain_capture_burndown"
end

Application.put_env(
  :fountain,
  FountainWeb.Endpoint,
  Application.get_env(:fountain, FountainWeb.Endpoint)
  |> Keyword.merge(server: true, http: [ip: {127, 0, 0, 1}, port: 4030], check_origin: false)
)

Application.put_env(:fountain, :api_cors_origins, [
  "http://127.0.0.1:5174",
  "http://127.0.0.1:5175",
  "http://127.0.0.1:5176"
])

Application.put_env(:fountain, :marketing_site, true)
{:ok, _} = Application.ensure_all_started(:fountain)
Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, :auto)
import Fountain.Factory
alias Fountain.Repo

user =
  Repo.get_by(Fountain.Accounts.User, email: "studio@example.com") ||
    insert_user_without_agents(email: "studio@example.com")

{:ok, user} =
  user
  |> Ecto.Changeset.change(
    onboarding_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
  )
  |> Repo.update()

{_, key} = insert_api_key(user)

env =
  Repo.get_by(Fountain.Environments.Environment, user_id: user.id, name: "storefront") ||
    insert_env(
      user_id: user.id,
      name: "storefront",
      description: "The Acorn storefront and its test suite"
    )

agent =
  insert_agent(
    user_id: user.id,
    name: "Builder",
    description: "Ships focused changes with tests",
    runtime: "claude",
    model: "anthropic/claude-sonnet-5",
    environment_id: env.id
  )

reviewer =
  insert_agent(
    user_id: user.id,
    name: "Reviewer",
    description: "Checks edge cases and explains tradeoffs",
    runtime: "codex",
    model: "openai/gpt-6-astra",
    environment_id: env.id
  )

researcher =
  insert_agent(
    user_id: user.id,
    name: "Researcher",
    description: "Turns questions into sourced answers",
    runtime: "gemini",
    model: "google/gemini-2.5-pro",
    environment_id: env.id
  )

now = DateTime.utc_now() |> DateTime.truncate(:second)

make_conv = fn a, title, channel, running ->
  sandbox =
    insert_sandbox(
      user_id: user.id,
      status: "suspended",
      machine_name: "acorn-" <> String.downcase(a.name),
      environment_id: env.id
    )

  conv =
    insert_conversation(
      user_id: user.id,
      agent: a,
      sandbox: sandbox,
      status: if(running, do: "running", else: "idle"),
      title: title,
      channel_id: channel,
      acp: true,
      last_active_at: now
    )

  turn =
    insert_turn(conv,
      prompt:
        "Add a clear empty state to the shopping cart. Keep the mobile layout readable and cover the new behavior with tests.",
      status: if(running, do: "running", else: "completed"),
      started_at: DateTime.add(now, -90)
    )

  event = fn update ->
    insert_log_event(conv,
      stream: "acp",
      turn_id: turn.id,
      data:
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "session/update",
          "params" => %{"sessionId" => "capture", "update" => update}
        })
    )
  end

  insert_log_event(conv,
    kind: "stage",
    stage: "turn",
    state: "started",
    turn_id: turn.id,
    data: Jason.encode!(%{turn_number: 1, turn_id: turn.id})
  )

  event.(%{
    "sessionUpdate" => "agent_message_chunk",
    "content" => %{
      "type" => "text",
      "text" =>
        "I found the cart component and its existing tests. I’m adding a useful empty state: a short explanation, a link back to the catalog, and spacing that works on a phone."
    }
  })

  event.(%{
    "sessionUpdate" => "tool_call",
    "toolCallId" => "read-cart",
    "title" => "Read src/components/Cart.tsx",
    "kind" => "read",
    "status" => "completed",
    "rawInput" => %{"file_path" => "src/components/Cart.tsx"}
  })

  event.(%{
    "sessionUpdate" => "tool_call",
    "toolCallId" => "edit-cart",
    "title" => "Update the empty cart",
    "kind" => "edit",
    "status" => "completed",
    "content" => [
      %{
        "type" => "diff",
        "path" => "src/components/Cart.tsx",
        "oldText" => "if (!items.length) return null;",
        "newText" => "if (!items.length) return <EmptyCart />;"
      }
    ]
  })

  event.(%{
    "sessionUpdate" => "agent_message_chunk",
    "content" => %{
      "type" => "text",
      "text" =>
        "The empty state is in place. The catalog link stays visible at narrow widths, and the cart total is hidden until there’s something to buy.\n\nI’m checking keyboard navigation and running the cart tests now."
    }
  })

  event.(%{
    "sessionUpdate" => "tool_call",
    "toolCallId" => "test-cart",
    "title" => "Run cart tests",
    "kind" => "execute",
    "status" => if(running, do: "in_progress", else: "completed"),
    "rawInput" => %{"command" => "npm test -- Cart.test.tsx"}
  })

  unless running,
    do:
      insert_log_event(conv,
        kind: "stage",
        stage: "turn",
        state: "done",
        turn_id: turn.id,
        data: Jason.encode!(%{turn_number: 1, turn_id: turn.id, exit_code: 0})
      )

  conv
end

conv = make_conv.(agent, "Make the empty cart feel useful", nil, true)
team = make_conv.(agent, "Polish the storefront", "fountain:team", false)
make_conv.(reviewer, "Review checkout edge cases", "fountain:team", false)
make_conv.(researcher, "Compare delivery options", "fountain:team", false)
capture_file = System.get_env("CAPTURE_DATA_FILE", "/tmp/fountain-capture-data.json")

File.write!(
  capture_file,
  Jason.encode!(%{
    api_key: key,
    user_id: user.id,
    agent_id: agent.id,
    reviewer_id: reviewer.id,
    env_id: env.id,
    conv_id: conv.id,
    team_conv_id: team.id
  })
)

File.chmod!(capture_file, 0o600)
import Ecto.Query
alias Fountain.Conversations.{Conversation, Turn, LogEvent}

for conv <- Repo.all(from c in Conversation, where: c.user_id == ^user.id, preload: [:agent]) do
  if conv.channel_id == "fountain:team",
    do: conv |> Ecto.Changeset.change(title: conv.agent.name) |> Repo.update!()

  turn = Repo.one!(from t in Turn, where: t.conversation_id == ^conv.id)

  if conv.agent.name == "Builder" do
    for {id, output} <- [
          {"read-cart", "src/components/Cart.tsx · 84 lines"},
          {"edit-cart",
           "--- a/src/components/Cart.tsx\n+++ b/src/components/Cart.tsx\n@@ -18,1 +18,5 @@\n- if (!items.length) return null;\n+ if (!items.length) return (\n+   <EmptyCart\n+     title=\"Your next favorite is out there\"\n+     href=\"/catalog\" />\n+ );"}
        ] do
      insert_log_event(conv,
        stream: "acp",
        turn_id: turn.id,
        data:
          Jason.encode!(%{
            jsonrpc: "2.0",
            method: "session/update",
            params: %{
              sessionId: "capture",
              update: %{
                sessionUpdate: "tool_call_update",
                toolCallId: id,
                status: "completed",
                rawOutput: output
              }
            }
          })
      )
    end
  else
    {prompt, answer} =
      if conv.agent.name == "Reviewer",
        do:
          {"Review the checkout flow for edge cases before we ship.",
           "I checked the checkout states. Two cases need attention before release: a saved cart with an unavailable item, and a shipping address outside the delivery area.\n\nI recommend keeping the cart intact in both cases and showing the next action beside the affected field."},
        else:
          {"Compare delivery options for the storefront launch.",
           "For launch, offer standard delivery and local pickup. They cover the two customer journeys without adding a delivery-date promise we cannot keep.\n\nI’ve outlined the copy and the address checks for each option."}

    turn |> Ecto.Changeset.change(prompt: prompt) |> Repo.update!()

    Repo.delete_all(
      from l in LogEvent, where: l.conversation_id == ^conv.id and l.stream == "acp"
    )

    insert_log_event(conv,
      stream: "acp",
      turn_id: turn.id,
      data:
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            sessionId: "capture",
            update: %{
              sessionUpdate: "agent_message_chunk",
              content: %{type: "text", text: answer}
            }
          }
        })
    )
  end
end

IO.puts("Capture server ready at http://127.0.0.1:4030")
Process.sleep(:infinity)
