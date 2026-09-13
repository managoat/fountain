defmodule FountainWeb.Schemas do
  @moduledoc """
  OpenAPI schemas shared across controllers. One module per resource so
  controller `operation` decls can reference them by atom (e.g.
  `Schemas.Agent`).
  """

  import FountainWeb.SchemaWrappers,
    only: [list_response: 2, item_response: 2, networking_config_description: 0]

  alias OpenApiSpex.Schema

  defmodule Sandbox do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Sandbox",
      description:
        "One machine. Provisioned for a conversation; several conversations may run on " <>
          "it at once (ADR 0023).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        sprite_name: %Schema{type: :string},
        status: %Schema{
          type: :string,
          enum: ~w(pending starting ready suspended terminated failed)
        },
        agent_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "The agent the machine was built for. With environment_id and vault_id it is " <>
              "the identity a conversation must match to attach (sandbox_id on create)."
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        vault_id: %Schema{type: :string, format: :uuid, nullable: true},
        mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          description:
            "ephemeral: one conversation's machine, reclaimed with it. persistent: the " <>
              "agent identity's home, shared by its conversations and kept when one ends."
        },
        url: %Schema{
          type: :string,
          nullable: true,
          description:
            "The sandbox's own HTTP endpoint, where a service the agent starts " <>
              "is reachable. Null for providers that expose no such URL. The " <>
              "same value is available inside the sandbox as `SANDBOX_URL`."
        },
        checkpoint: %Schema{
          type: :object,
          nullable: true,
          description:
            "The checkpoint Fountain took of this home the last time it parked " <>
              "(ADR 0023). It is scoped to this machine: it can roll the machine " <>
              "back, not rebuild a machine that is gone. Null for an ephemeral " <>
              "sandbox, a provider without checkpoints, or a home that has not " <>
              "parked yet.",
          properties: %{
            id: %Schema{type: :string},
            at: %Schema{type: :string, format: :"date-time", nullable: true}
          }
        },
        provider: %Schema{
          type: :string,
          enum: ~w(sprites e2b daytona runner),
          description: "The sandbox backend this row lives on."
        },
        runner: %Schema{
          type: :object,
          nullable: true,
          description:
            "For `provider: runner` — the user's own machine the sandbox lives on, " <>
              "and its directory there (#834). Null for hosted providers; the inner " <>
              "fields are null when the runner row was forgotten.",
          properties: %{
            id: %Schema{type: :string, format: :uuid, nullable: true},
            name: %Schema{type: :string, nullable: true},
            hostname: %Schema{type: :string, nullable: true},
            online: %Schema{
              type: :boolean,
              description: "Whether the runner daemon is connected right now."
            },
            path: %Schema{
              type: :string,
              nullable: true,
              description: "The sandbox directory on the machine (`<root>/<name>`)."
            }
          },
          required: [:online]
        }
      },
      required: [:id, :sprite_name, :status]
    })
  end

  defmodule SandboxConversation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxConversation",
      description: "A conversation on a sandbox, as the sandbox lists it.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: ~w(pending running idle failed terminated)},
        title: %Schema{type: :string, nullable: true},
        runtime: %Schema{type: :string, enum: Fountain.Agents.Agent.known_runtimes()},
        mid_turn: %Schema{
          type: :boolean,
          description: "True while this conversation is running a turn on the machine."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :status, :mid_turn]
    })
  end

  defmodule SandboxDetail do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxDetail",
      description: "A sandbox with the conversations on it.",
      type: :object,
      properties:
        Map.merge(Sandbox.schema().properties, %{
          conversations: %Schema{
            type: :array,
            items: SandboxConversation,
            description: "Every conversation ever opened on this machine, newest first."
          },
          inserted_at: %Schema{type: :string, format: :"date-time"},
          last_resumed_at: %Schema{type: :string, format: :"date-time", nullable: true}
        }),
      required: [:id, :sprite_name, :status, :conversations]
    })
  end

  defmodule SandboxEntry do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxEntry",
      description: "One entry of a directory on a sandbox (ADR 0039).",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        type: %Schema{type: :string, enum: Fountain.SandboxFiles.entry_types()},
        size: %Schema{
          type: :integer,
          nullable: true,
          description: "Bytes, for a regular file; null otherwise."
        }
      },
      required: [:name, :type]
    })
  end

  defmodule SandboxListing do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxListing",
      description: "A directory on a sandbox, directories first then by name.",
      type: :object,
      properties: %{
        path: %Schema{type: :string, description: "The directory listed, absolute."},
        entries: %Schema{type: :array, items: SandboxEntry},
        truncated: %Schema{
          type: :boolean,
          description: "True when the directory holds more entries than were returned."
        }
      },
      required: [:path, :entries, :truncated]
    })
  end

  defmodule SandboxFile do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxFile",
      description:
        "One file on a sandbox, redacted: the sandbox's environment and vault values " <>
          "read `[REDACTED]`.",
      type: :object,
      properties: %{
        path: %Schema{type: :string, description: "The file read, absolute."},
        size: %Schema{type: :integer, description: "The whole file, in bytes."},
        truncated: %Schema{
          type: :boolean,
          description:
            "True when `content` is not the whole file: either the file is longer than " <>
              "`max_bytes`, or redaction grew what was read past it. False means `content` " <>
              "is everything."
        },
        encoding: %Schema{
          type: :string,
          enum: Fountain.SandboxFiles.encodings(),
          description:
            "`utf-8` when `content` is the text itself; `base64` when it is not valid UTF-8."
        },
        content: %Schema{type: :string}
      },
      required: [:path, :size, :truncated, :encoding, :content]
    })
  end

  defmodule SandboxDiff do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxDiff",
      description: "`git diff` of a repository on a sandbox, redacted like a file.",
      type: :object,
      properties: %{
        path: %Schema{
          type: :string,
          description: "The directory the diff was asked for, absolute."
        },
        repo_root: %Schema{type: :string, description: "The repository's top-level directory."},
        staged: %Schema{
          type: :boolean,
          description: "True when the index was diffed (`--cached`)."
        },
        ref: %Schema{
          type: :string,
          nullable: true,
          description: "The revision diffed against, or null when the caller named none."
        },
        diff: %Schema{type: :string, description: "Unified diff, no colour."},
        truncated: %Schema{
          type: :boolean,
          description:
            "True when `diff` is not the whole diff: either it is longer than `max_bytes`, " <>
              "or redaction grew what was read past it. False means `diff` is everything."
        }
      },
      required: [:path, :repo_root, :staged, :diff, :truncated]
    })
  end

  defmodule SandboxChange do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxChange",
      description:
        "One path `git status` reports, relative to `repo_root` (ADR 0039). " <>
          "An untracked file reads `untracked` on both sides, which is what git " <>
          "reports for it and the one state a diff cannot show.",
      type: :object,
      properties: %{
        path: %Schema{type: :string, description: "Relative to `repo_root`."},
        index: %Schema{
          type: :string,
          enum: Fountain.SandboxFiles.change_states(),
          description: "The staged side: what a commit would record."
        },
        worktree: %Schema{
          type: :string,
          enum: Fountain.SandboxFiles.change_states(),
          description: "The unstaged side: what the disk holds beyond the index."
        },
        renamed_from: %Schema{
          type: :string,
          nullable: true,
          description: "The old path, when that side is a rename or a copy; null otherwise."
        }
      },
      required: [:path, :index, :worktree]
    })
  end

  defmodule SandboxStatus do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxStatus",
      description: "`git status` of a repository on a sandbox, one entry per changed path.",
      type: :object,
      properties: %{
        path: %Schema{
          type: :string,
          description: "The directory the status was asked for, absolute."
        },
        repo_root: %Schema{type: :string, description: "The repository's top-level directory."},
        branch: %Schema{
          type: :string,
          nullable: true,
          description: "The checked-out branch, or null on a detached HEAD."
        },
        untracked: %Schema{
          type: :string,
          enum: Fountain.SandboxFiles.untracked_modes(),
          description: "What was asked about untracked paths."
        },
        entries: %Schema{type: :array, items: SandboxChange},
        truncated: %Schema{
          type: :boolean,
          description: "True when the repository holds more changes than were returned."
        }
      },
      required: [:path, :repo_root, :untracked, :entries, :truncated]
    })
  end

  defmodule UsageAccounting do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UsageAccounting",
      description:
        "The adapter's accounting claim, not independently verified billing. " <>
          "Interpret source, version and scope together. Reported does not imply whole-conversation coverage.",
      type: :object,
      properties: %{
        version: %Schema{type: :integer, minimum: 1},
        source: %Schema{type: :string, minLength: 1, maxLength: 256},
        scope: %Schema{type: :string, minLength: 1, maxLength: 256},
        completeness: %Schema{type: :string, enum: ["reported", "partial"]}
      },
      required: [:version, :source, :scope, :completeness]
    })
  end

  defmodule TurnUsage do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TurnUsage",
      description:
        "The turn's token usage as the runtime reported it when the turn ended " <>
          "(the ACP `session/prompt` response's `usage`). The cache fields appear " <>
          "only when the runtime reports them. Accounting is absent for unqualified or historical reports. " <>
          "A metadata-only report has no measured token counts; missing counts are not zero.",
      type: :object,
      properties: %{
        accounting: UsageAccounting,
        input: %Schema{type: :integer, minimum: 0},
        output: %Schema{type: :integer, minimum: 0},
        cache_read: %Schema{type: :integer, minimum: 0, nullable: true},
        cache_write: %Schema{type: :integer, minimum: 0, nullable: true}
      },
      required: []
    })
  end

  defmodule UsageTotal do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UsageTotal",
      description: "Running sums of `input` and `output` over the turns that reported a usage.",
      type: :object,
      properties: %{
        input: %Schema{type: :integer, minimum: 0},
        output: %Schema{type: :integer, minimum: 0}
      },
      required: [:input, :output]
    })
  end

  defmodule PendingPermissionRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PendingPermissionRequest",
      description:
        "A permission request that outlived its turn (#1635). The agent ended the " <>
          "turn with stop reason `waiting` while this request was open, so the " <>
          "conversation is idle, the sandbox may be suspended, and the request is " <>
          "still waiting for an answer. Answer it at " <>
          "POST /api/conversations/{id}/requests/{request_id}, which resolves it and " <>
          "opens a new turn carrying the outcome to the agent.",
      type: :object,
      properties: %{
        request_id: %Schema{type: :string},
        tool: %Schema{
          type: :string,
          nullable: true,
          description: "The tool the agent asked about, as the transcript labels it."
        },
        options: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true},
          description:
            "The options the agent offered, verbatim. `option_id` must be one of " <>
              "these `optionId` values; an id from another runtime is refused."
        },
        asked_at: %Schema{type: :string, format: :"date-time", nullable: true},
        deadline: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description:
            "When the request is denied for want of an answer. Set from the " <>
              "request's own `_meta.fountain.timeout`, else the policy's " <>
              "`ask_timeout`, else the global ask timeout."
        },
        turn_id: %Schema{type: :string, format: :uuid}
      },
      required: [:request_id, :options]
    })
  end

  defmodule Conversation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Conversation",
      description: "One chat with one agent inside one sandbox.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        title: %Schema{
          type: :string,
          nullable: true,
          description: "Generated from the first turn; null until one exists."
        },
        sandbox_id: %Schema{type: :string, format: :uuid, nullable: true},
        sandbox: %Schema{oneOf: [Sandbox], nullable: true},
        agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        agent_version_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "The agent config version this conversation launched under (ADR 0029): " <>
              "provenance only, the live agent still drives the sandbox. Null for a " <>
              "conversation that predates versioning. Resolve it at " <>
              "GET /api/agents/{agent_id}/versions/{agent_version}."
        },
        agent_version: %Schema{
          type: :integer,
          nullable: true,
          readOnly: true,
          description:
            "The version number behind agent_version_id, resolved on the list and get " <>
              "endpoints; null elsewhere and wherever agent_version_id is null."
        },
        vault_id: %Schema{type: :string, format: :uuid, nullable: true},
        sandbox_api_access: %Schema{
          type: :string,
          enum: ~w(owner none),
          description:
            "Immutable sandbox callback credential policy. none never issues a callback token."
        },
        permission_policy: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            ask_timeout: %Schema{
              type: :integer,
              minimum: 1,
              maximum: Fountain.PermissionPolicy.max_ask_timeout_seconds(),
              description:
                "Seconds a permission request that outlived its turn waits before it " <>
                  "is denied (#1635). Names no tool, so it is the one key whose value " <>
                  "is a number rather than a verdict, which is why the value schema " <>
                  "below is a union. Absent leaves the global ask timeout. A request " <>
                  "may shorten it with `_meta.fountain.timeout` on its own " <>
                  "session/request_permission, and may not lengthen it. A launch may " <>
                  "only shorten what the agent set, or the global ask timeout where " <>
                  "the agent set nothing. Capped at a year, which is where the " <>
                  "deadline stops fitting in a timestamp rather than a limit on how " <>
                  "long a wait is useful."
            }
          },
          additionalProperties: %Schema{
            oneOf: [
              %Schema{type: :string, enum: Managoat.ACP.Permissions.buildable_verdicts()},
              %Schema{type: :integer, minimum: 1}
            ]
          },
          description:
            "The per-launch permission override this conversation was started with, or " <>
              "null if it had none. The policy actually in force is this merged with the " <>
              "agent's, taking the stricter of the two per tool."
        },
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Per-launch environment override; null means the agent's environment."
        },
        runtime: %Schema{type: :string, enum: Fountain.Agents.Agent.known_runtimes()},
        acp: %Schema{
          type: :boolean,
          readOnly: true,
          description:
            "Whether this conversation's runtime speaks the Agent Client Protocol. " <>
              "When true its output is stored as ACP `session/update` notifications on " <>
              "the `acp` event stream, which is what a protocol client replays; when " <>
              "false the output is the runtime's own dialect on `stdout`."
        },
        status: %Schema{
          type: :string,
          enum: ~w(pending running idle failed terminated)
        },
        runtime_session_id: %Schema{type: :string, nullable: true},
        source: %Schema{type: :string, enum: ~w(ui api agent)},
        parent_conversation_id: %Schema{type: :string, format: :uuid, nullable: true},
        channel_id: %Schema{
          type: :string,
          nullable: true,
          description:
            "The external channel key this conversation is bound to, if it was created with one."
        },
        labels: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :string},
          description:
            "Free-form key/value strings on the conversation. A program stamps its own " <>
              "run with them (`env=prod`, `drift=true`) and `GET /api/conversations?label=env:prod` " <>
              "filters on them. At most 32 entries; a key is at most 64 bytes and a value " <>
              "at most 256 bytes. Always an object, empty when nothing set one."
        },
        turn_count: %Schema{type: :integer},
        first_prompt: %Schema{
          type: :string,
          nullable: true,
          readOnly: true,
          description:
            "The first turn's prompt — what to title an untitled conversation " <>
              "with. Null until the first turn exists."
        },
        last_active_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description:
            "Most recent runtime output, falling back to creation time. Stage " <>
              "events (reconnects, sandbox lifecycle) do not count."
        },
        last_read_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Set by `POST /api/conversations/:id/read`. Null if never read."
        },
        unread: %Schema{
          type: :boolean,
          description: "last_active_at is later than last_read_at (true if never read)."
        },
        usage_total: UsageTotal,
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"},
        pending_requests: %Schema{
          type: :array,
          items: PendingPermissionRequest,
          description:
            "Permission requests that outlived a turn and are still waiting for an " <>
              "answer (#1635). Served on GET /api/conversations/{id} only; absent " <>
              "from the list and from the create response."
        }
      },
      required: [:id, :runtime, :status]
    })
  end

  defmodule ConversationTreeNode do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationTreeNode",
      description: "One conversation in a spawn tree, flat with a parent pointer.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        source: %Schema{type: :string, enum: ~w(ui api agent)},
        status: %Schema{type: :string, enum: ~w(pending running idle failed terminated)},
        parent_id: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [:id]
    })
  end

  list_response(ConversationTreeResponse, of: ConversationTreeNode)

  item_response(ConversationResponse, of: Conversation)

  list_response(ConversationListResponse, of: Conversation)

  defmodule ImageInput do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ImageInput",
      description: "A base64-encoded image to attach to a prompt.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :string,
          description: "Base64-encoded image bytes."
        },
        media_type: %Schema{
          type: :string,
          enum: ~w(image/png image/jpeg image/gif image/webp),
          description: "MIME type of the image."
        }
      },
      required: [:data, :media_type]
    })
  end

  defmodule ConversationCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationCreateRequest",
      type: :object,
      properties: %{
        agent_id: %Schema{type: :string, format: :uuid},
        vault_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional vault whose secrets override the environment's baseline at sprite spawn. " <>
              "Must satisfy the agent's allowed_vault_ids when that allowlist is set."
        },
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional environment to provision from instead of the agent's own; the " <>
              "conversation stays pinned to it across wakes. Must be owned by the caller " <>
              "(404 otherwise) and satisfy the agent's allowed_environment_ids when that " <>
              "allowlist is set (422 environment_not_allowed). Part of the channel_id " <>
              "resume key."
        },
        sandbox_api_access: %Schema{
          type: :string,
          enum: ~w(owner none),
          description:
            "none omits the sandbox Fountain credential on provision and every wake. Requires a fresh ephemeral sandbox; unavailable on attach or policy-changing channel resume."
        },
        permission_policy: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            ask_timeout: %Schema{
              type: :integer,
              minimum: 1,
              maximum: Fountain.PermissionPolicy.max_ask_timeout_seconds(),
              description:
                "Seconds a permission request that outlived its turn waits before it " <>
                  "is denied (#1635). Names no tool, so it is the one key whose value " <>
                  "is a number rather than a verdict, which is why the value schema " <>
                  "below is a union. Absent leaves the global ask timeout. A request " <>
                  "may shorten it with `_meta.fountain.timeout` on its own " <>
                  "session/request_permission, and may not lengthen it. A launch may " <>
                  "only shorten what the agent set, or the global ask timeout where " <>
                  "the agent set nothing. Capped at a year, which is where the " <>
                  "deadline stops fitting in a timestamp rather than a limit on how " <>
                  "long a wait is useful."
            }
          },
          additionalProperties: %Schema{
            oneOf: [
              %Schema{type: :string, enum: Managoat.ACP.Permissions.buildable_verdicts()},
              %Schema{type: :integer, minimum: 1}
            ]
          },
          description:
            "Per-launch permission override (#939). Keys are matched against the tool " <>
              "card's title first and then ACP's kind (execute, edit, read, fetch, …); " <>
              "\"default\" covers the rest. Prefer a kind: claude titles a tool call with " <>
              "the command it is about to run, so a title matches one invocation only. " <>
              "Merged with the agent's own policy, taking the stricter of the two. It may " <>
              "only narrow: a policy that would loosen any tool is refused with 422 " <>
              "permission_policy_widens rather than silently clamped, and one the runtime " <>
              "never consults is refused with 422 permission_policy_unenforceable."
        },
        prompt: %Schema{
          type: :string,
          description:
            "Optional first turn prompt. A launch may open with no prompt at all, but a " <>
              "prompt that is present must carry words: blank and whitespace-only text is " <>
              "refused with 422 invalid_prompt, before the launch reserves a sandbox."
        },
        title: %Schema{
          type: :string,
          nullable: true,
          maxLength: 120,
          description: "Optional display title. The team page names a teammate with it."
        },
        images: %Schema{
          type: :array,
          items: ImageInput,
          description:
            "Optional images to attach to the initial prompt. They require that prompt: " <>
              "images with no opening text are refused with 422 invalid_prompt, and an " <>
              "image whose media_type is unsupported or whose decoded bytes are empty or " <>
              "over the 10MB ceiling is refused with 422 invalid_images. Both refusals " <>
              "happen before a sandbox is reserved.",
          nullable: true
        },
        sprite_name: %Schema{
          type: :string,
          description:
            "Name the conversation's machine instead of taking a generated name. " <>
              "The value is the suffix of an account-scoped name: the server keeps the " <>
              "fountain-<account>- prefix every generated name carries, so a name you " <>
              "choose lands in your own namespace rather than another account's. " <>
              "1 to 40 characters of letters, digits, - and _, starting with a letter " <>
              "or digit; a name that already carries this account's prefix is taken as " <>
              "it stands, so a name from an earlier launch resolves to the same machine. " <>
              "422 invalid_sprite_name otherwise. Refused with 422 " <>
              "sprite_name_not_supported on an agent that runs on a self-hosted runner, " <>
              "where the name carries the runner instead. Refused with " <>
              "sandbox_api_access none, which requires a machine no other conversation " <>
              "can reach."
        },
        sandbox_mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          nullable: true,
          description:
            "Where this conversation runs (ADR 0023); null takes the agent's sandbox_mode. " <>
              "persistent lands on the agent identity's home — provisioning it if this is " <>
              "the first launch of that (agent, environment, vault), attaching to it " <>
              "otherwise, or 503 provisioning while the first launch is still building it. " <>
              "ephemeral provisions a sandbox for this conversation alone. Ignored when " <>
              "sandbox_id names a machine."
        },
        sandbox_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Attach the conversation to a sandbox you already have instead of provisioning " <>
              "one (ADR 0023). The sandbox must be yours (404 sandbox_not_found), ready or " <>
              "suspended (409 sandbox_not_attachable), and built for the same agent, " <>
              "environment and vault as this launch (422 sandbox_identity_mismatch; 422 " <>
              "sandbox_runtime_mismatch if the agent's runtime changed since). The " <>
              "conversation opens idle on that machine; a prompt here wakes it. Several " <>
              "conversations then run on one disk at once, except on opencode and gemini, " <>
              "where a second turn is refused with 409 sandbox_at_capacity while one runs."
        },
        channel_id: %Schema{
          type: :string,
          maxLength: 255,
          nullable: true,
          description:
            "Opaque key for the external channel this conversation is bound to (for example a " <>
              "Buzz channel id). When set, the latest live conversation for the same agent, vault " <>
              "and channel is resumed (200) instead of a new one being opened (201)."
        },
        fresh: %Schema{
          type: :boolean,
          nullable: true,
          description:
            "With channel_id: skip the resume and open a new conversation (201), which then " <>
              "becomes the channel's binding. Sent by a chat harness relaying its owner's " <>
              "rotate command. Ignored without channel_id."
        },
        labels: %Schema{
          type: :object,
          nullable: true,
          additionalProperties: %Schema{type: :string},
          description:
            "Key/value strings to stamp on the conversation. At most 32 entries; a key is " <>
              "at most 64 bytes and a value at most 256 bytes, and a 422 names the offending " <>
              "key under `errors.labels`. With channel_id, a resume merges these into the " <>
              "conversation it hands back rather than dropping them."
        },
        queue: %Schema{
          type: :boolean,
          nullable: true,
          description:
            "When a fresh start reaches the tenant or the fleet concurrency ceiling, wait " <>
              "in the bounded sandbox queue and return 202 with a SandboxRequest instead " <>
              "of 429 or 503 (ADR 0042). Starts carrying images or an explicit sandbox_id " <>
              "are never queued, and a full queue keeps the immediate error."
        }
      },
      required: [:agent_id]
    })
  end

  defmodule SandboxRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SandboxRequest",
      description: "Work waiting for sandbox capacity (ADR 0042).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        agent_id: %Schema{type: :string, format: :uuid},
        kind: %Schema{type: :string, enum: Fountain.SandboxQueue.Request.kinds()},
        status: %Schema{type: :string, enum: Fountain.SandboxQueue.Request.statuses()},
        source: %Schema{type: :string, nullable: true},
        conversation_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "The conversation the request became, once it started."
        },
        error: %Schema{type: :string, nullable: true},
        position: %Schema{
          type: :integer,
          nullable: true,
          description: "One-based place in the tenant's queue; null once it stops waiting."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :agent_id, :kind, :status]
    })
  end

  item_response(SandboxRequestResponse, of: SandboxRequest)
  list_response(SandboxRequestListResponse, of: SandboxRequest)

  defmodule ConversationLabelsRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationLabelsRequest",
      description:
        "Labels to merge into a conversation. A key not named is left alone; a key whose " <>
          "value is null is removed.",
      type: :object,
      properties: %{
        labels: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :string, nullable: true},
          description:
            "The pairs to merge. null removes a key. At most 32 entries survive the merge; " <>
              "a key is at most 64 bytes and a value at most 256 bytes. A 422 names the " <>
              "offending key under `errors.labels`."
        }
      },
      required: [:labels]
    })
  end

  defmodule ConversationReapplyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationReapplyRequest",
      description:
        "A selection of Agent, Environment and Vault to apply to the machine an existing " <>
          "conversation already runs on. An omitted field keeps its current selection. An " <>
          "explicit null clears the Environment override or the Vault. An empty object " <>
          "reapplies the current selection.",
      type: :object,
      properties: %{
        agent_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Agent to use; omitted keeps the current Agent."
        },
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Environment override to use; null returns to the selected Agent's Environment."
        },
        vault_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Vault to use; null detaches the current Vault."
        }
      }
    })
  end

  defmodule PromptRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PromptRequest",
      type: :object,
      properties: %{
        prompt: %Schema{type: :string},
        images: %Schema{
          type: :array,
          items: ImageInput,
          description: "Optional images to attach to this prompt.",
          nullable: true
        }
      },
      required: [:prompt]
    })
  end

  defmodule PromptResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PromptResponse",
      type: :object,
      properties: %{status: %Schema{type: :string, example: "queued"}},
      required: [:status]
    })
  end

  defmodule PermissionAnswerRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PermissionAnswerRequest",
      type: :object,
      properties: %{
        option_id: %Schema{
          type: :string,
          description:
            "One of the `optionId` values from the request's own `options` list, as " <>
              "carried on the `permission_request` block. An id the agent did not offer " <>
              "is refused (422 unknown_option) rather than forwarded."
        }
      },
      required: [:option_id]
    })
  end

  defmodule PermissionAnswerResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PermissionAnswerResponse",
      type: :object,
      properties: %{ok: %Schema{type: :boolean, example: true}},
      required: [:ok]
    })
  end

  defmodule Turn do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Turn",
      description: "One prompt → exit_code cycle within a conversation.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        turn_number: %Schema{type: :integer},
        prompt: %Schema{type: :string},
        status: %Schema{
          type: :string,
          enum: ~w(pending running completed failed interrupted)
        },
        # No `default:` here on purpose: one would make the generated TS
        # field non-optional (see sdk/typescript notes).
        origin: %Schema{
          type: :string,
          enum: ~w(user autonomous),
          description:
            "Who opened the turn: `user` for a prompt somebody sent, `autonomous` " <>
              "for a turn the server opened for a background cycle the agent ran " <>
              "after its prompt was answered (#817)."
        },
        waiting: %Schema{
          type: :boolean,
          description:
            "The turn ended with a permission request still open (#1635): the agent " <>
              "answered with stop reason `waiting`, the turn is `completed` and the " <>
              "request is on the conversation as a `pending_requests` entry."
        },
        exit_code: %Schema{type: :integer, nullable: true},
        limit_reason: %Schema{
          type: :string,
          nullable: true,
          description:
            "The service-enforced limit that ended this turn, or null. Set independently of exit_code: a runtime that exits zero after its deadline is still an incomplete turn, so a client must read this before treating a turn as successful."
        },
        started_at: %Schema{type: :string, format: :"date-time", nullable: true},
        ended_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        image_count: %Schema{
          type: :integer,
          description: "Number of images attached to this turn."
        },
        model_selection: %Schema{
          type: :object,
          nullable: true,
          description: "ACP model selection evidence; null for turns without a selection report.",
          properties: %{
            requested_model: %Schema{type: :string, nullable: true},
            effective_model: %Schema{type: :string, nullable: true},
            status: %Schema{type: :string, enum: ~w(selected failed)},
            source: %Schema{type: :string, enum: ~w(runtime selection_ack), nullable: true},
            error: %Schema{type: :string}
          }
        },
        usage: %Schema{
          oneOf: [TurnUsage],
          nullable: true,
          description:
            "The end-of-turn token figure; null while the turn runs, when the runtime " <>
              "reported none, or on turns that predate the field."
        }
      },
      required: [:id, :turn_number, :prompt, :status]
    })
  end

  list_response(TurnListResponse, of: Turn)

  defmodule Agent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Agent",
      description: "An AI agent definition: runtime, model, skills, MCP, env.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        description: %Schema{type: :string},
        system: %Schema{type: :string, description: "System prompt."},
        model: %Schema{
          type: :string,
          description:
            "Canonical provider/model_id (e.g. anthropic/claude-sonnet-5). The " <>
              "provider must match the runtime — anthropic for claude, openai for " <>
              "codex, google for gemini; opencode accepts any of the three. Other " <>
              "providers are rejected: Fountain has no credentials to export for " <>
              "them. The model id is not checked against a list, so a newly " <>
              "released model works without a Fountain release. The isolated fountain-fixture " <>
              "runtime is the exception: it accepts only fixture/deterministic-v1. Null " <>
              "on the acp runtime, which resolves no inference credential and reads no " <>
              "model.",
          nullable: true,
          pattern: "^[a-z0-9_-]+/[a-z0-9._-]+$"
        },
        runtime: %Schema{type: :string, enum: Fountain.Agents.Agent.known_runtimes()},
        runtime_command: %Schema{
          type: :string,
          nullable: true,
          description:
            "The command the acp runtime launches inside the sandbox, as a shell line " <>
              "resolved there (for example `chant acp`). Required when runtime is " <>
              "acp, and rejected on every other runtime, which resolves its own " <>
              "executable. A free string by design: it runs under the same isolation " <>
              "as an environment's setup script."
        },
        acp: %Schema{
          type: :boolean,
          readOnly: true,
          description:
            "Whether this agent's runtime speaks the Agent Client Protocol. Derived " <>
              "from the runtime, never stored. When false, the conversation's output " <>
              "is the runtime's own dialect on the `stdout` stream rather than ACP " <>
              "`session/update` notifications on the `acp` stream, and a protocol " <>
              "client such as `fountain acp` cannot render it."
        },
        sandbox_provider: %Schema{
          type: :string,
          enum: ~w(sprites e2b daytona runner),
          nullable: true,
          description:
            "Sandbox backend override; null inherits the instance default " <>
              "(SANDBOX_PROVIDER). Only providers configured on this instance are accepted"
        },
        sandbox_mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          description:
            "Where a conversation of this agent runs by default (ADR 0023). ephemeral: a " <>
              "sandbox per conversation, reclaimed with it. persistent: one sandbox per " <>
              "agent identity (agent, environment, vault) — the agent's computer — that " <>
              "every conversation of that identity lands on and shares; it survives a " <>
              "conversation ending and is parked, not destroyed, at the ceiling. A launch " <>
              "may name the other with sandbox_mode on POST /api/conversations."
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        permission_policy: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            ask_timeout: %Schema{
              type: :integer,
              minimum: 1,
              maximum: Fountain.PermissionPolicy.max_ask_timeout_seconds(),
              description:
                "Seconds a permission request that outlived its turn waits before it " <>
                  "is denied (#1635). Names no tool, so it is the one key whose value " <>
                  "is a number rather than a verdict, which is why the value schema " <>
                  "below is a union. Absent leaves the global ask timeout. A request " <>
                  "may shorten it with `_meta.fountain.timeout` on its own " <>
                  "session/request_permission, and may not lengthen it. A launch may " <>
                  "only shorten what the agent set, or the global ask timeout where " <>
                  "the agent set nothing. Capped at a year, which is where the " <>
                  "deadline stops fitting in a timestamp rather than a limit on how " <>
                  "long a wait is useful."
            }
          },
          additionalProperties: %Schema{
            oneOf: [
              %Schema{type: :string, enum: Managoat.ACP.Permissions.buildable_verdicts()},
              %Schema{type: :integer, minimum: 1}
            ]
          },
          description:
            "Per-tool permission policy: a map of key to verdict, plus an optional " <>
              "\"default\" key. A key is matched against the tool card's title first and " <>
              "then ACP's kind (execute, edit, read, fetch, \u2026); prefer a kind, because " <>
              "claude titles a tool call with the command it is about to run. Unset keys " <>
              "fall back to the default, and an unset default is auto_allow \u2014 today's " <>
              "behaviour. \"ask\" holds the tool until a human answers it on the " <>
              "conversation stream, and denies if nobody does before the timeout. A " <>
              "runtime that never asks (opencode) refuses anything stricter than " <>
              "auto_allow with 422 permission_policy_unenforceable."
        },
        skills: %Schema{
          type: :array,
          description:
            "Each entry is either inline (`{name, content}` — full SKILL.md text written to the sprite) " <>
              "or github (`{source, ref?, name?}` — installed on the sprite via the skills.sh CLI, " <>
              "optionally pinned to a tag/branch/sha via `ref`). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{
                type: :string,
                description: "Skill name (required for inline entries)."
              },
              content: %Schema{
                type: :string,
                description: "Full SKILL.md body for inline entries."
              },
              source: %Schema{
                type: :string,
                description: "GitHub `owner/repo` for skills.sh-sourced entries.",
                pattern: "^[A-Za-z0-9._/-]+$"
              },
              ref: %Schema{
                type: :string,
                description:
                  "Optional tag, branch, or sha pinning a github-sourced skill " <>
                    "(installed as `owner/repo@ref`). Without it the default branch " <>
                    "is fetched at spawn time.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        allowed_vault_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Vaults a conversation may attach to this agent. null (default) allows " <>
              "any vault the tenant owns; an empty list forbids attaching any vault; " <>
              "a non-empty list is an allowlist. Vault values override the agent's " <>
              "environment on key collision, so this scopes who can override reviewed config."
        },
        allowed_environment_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Environments a conversation may launch this agent under instead of its own " <>
              "(environment_id on create). Same shape as allowed_vault_ids: null (default) " <>
              "allows any environment the tenant owns; an empty list forbids overriding; " <>
              "a non-empty list is an allowlist. The agent's own environment always passes."
        },
        conversation_count: %Schema{
          type: :integer,
          description: "Conversations started from this agent."
        },
        avatar_media_type: %Schema{
          type: :string,
          nullable: true,
          enum: ~w(image/png image/jpeg image/gif image/webp),
          description:
            "Set when the agent has an avatar; fetch the bytes at " <>
              "`GET /api/agents/:id/avatar`. Null means no avatar."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      # `model` stays required: the response always carries the key, and the
      # acp runtime's value for it is null rather than absent.
      required: [:id, :name, :model, :runtime]
    })
  end

  item_response(AgentResponse, of: Agent)

  list_response(AgentListResponse, of: Agent)

  defmodule AgentVersion do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentVersion",
      description:
        "One immutable snapshot of an agent's config (ADR 0029), written on create and on " <>
          "every update that changes a config field. `config` holds the full values, keyed " <>
          "by the agent fields `Agent.changeset/2` casts (everything but ownership and the " <>
          "avatar). Versions are read-only over the API; rollback is a console action.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        agent_id: %Schema{type: :string, format: :uuid},
        version: %Schema{type: :integer, description: "1-based, monotonic per agent."},
        config: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :agent_id, :version, :config, :inserted_at]
    })
  end

  item_response(AgentVersionResponse, of: AgentVersion)

  list_response(AgentVersionListResponse, of: AgentVersion)

  defmodule AgentRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string},
        system: %Schema{type: :string},
        model: %Schema{
          type: :string,
          # Nullable so an agent converted to the acp runtime can clear the
          # model it no longer uses. CastAndValidate runs before the
          # changeset, so a non-nullable string here would reject the null
          # with a 400 and leave the stale value on the row forever.
          nullable: true,
          pattern: "^[a-z0-9_-]+/[a-z0-9._-]+$"
        },
        runtime: %Schema{type: :string, enum: Fountain.Agents.Agent.known_runtimes()},
        runtime_command: %Schema{
          type: :string,
          nullable: true,
          description:
            "The command the acp runtime launches inside the sandbox, as a shell line " <>
              "resolved there (for example `chant acp`). Required when runtime is " <>
              "acp, and rejected on every other runtime, which resolves its own " <>
              "executable. A free string by design: it runs under the same isolation " <>
              "as an environment's setup script."
        },
        sandbox_provider: %Schema{
          type: :string,
          enum: ~w(sprites e2b daytona runner),
          nullable: true,
          description:
            "Sandbox backend override; null inherits the instance default " <>
              "(SANDBOX_PROVIDER). Only providers configured on this instance are accepted"
        },
        sandbox_mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          description:
            "Where a conversation of this agent runs by default (ADR 0023). ephemeral: a " <>
              "sandbox per conversation, reclaimed with it. persistent: one sandbox per " <>
              "agent identity (agent, environment, vault) — the agent's computer — that " <>
              "every conversation of that identity lands on and shares; it survives a " <>
              "conversation ending and is parked, not destroyed, at the ceiling. A launch " <>
              "may name the other with sandbox_mode on POST /api/conversations."
        },
        permission_policy: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            ask_timeout: %Schema{
              type: :integer,
              minimum: 1,
              maximum: Fountain.PermissionPolicy.max_ask_timeout_seconds(),
              description:
                "Seconds a permission request that outlived its turn waits before it " <>
                  "is denied (#1635). Names no tool, so it is the one key whose value " <>
                  "is a number rather than a verdict, which is why the value schema " <>
                  "below is a union. Absent leaves the global ask timeout. A request " <>
                  "may shorten it with `_meta.fountain.timeout` on its own " <>
                  "session/request_permission, and may not lengthen it. A launch may " <>
                  "only shorten what the agent set, or the global ask timeout where " <>
                  "the agent set nothing. Capped at a year, which is where the " <>
                  "deadline stops fitting in a timestamp rather than a limit on how " <>
                  "long a wait is useful."
            }
          },
          additionalProperties: %Schema{
            oneOf: [
              %Schema{type: :string, enum: Managoat.ACP.Permissions.buildable_verdicts()},
              %Schema{type: :integer, minimum: 1}
            ]
          },
          description:
            "Per-tool permission policy: a map of key to verdict, plus an optional " <>
              "\"default\" key. A key is matched against the tool card's title first and " <>
              "then ACP's kind (execute, edit, read, fetch, \u2026); prefer a kind, because " <>
              "claude titles a tool call with the command it is about to run. Unset keys " <>
              "fall back to the default, and an unset default is auto_allow. \"ask\" holds " <>
              "the tool until a human answers it on the conversation stream, and denies if " <>
              "nobody does before the timeout. A conversation may narrow this at launch, " <>
              "never widen it. A runtime that never asks (opencode) refuses anything " <>
              "stricter than auto_allow with 422 permission_policy_unenforceable."
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        skills: %Schema{
          type: :array,
          description:
            "Each entry is either inline (`{name, content}` — full SKILL.md text written to the sprite) " <>
              "or github (`{source, ref?, name?}` — installed on the sprite via the skills.sh CLI, " <>
              "optionally pinned to a tag/branch/sha via `ref`). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{
                type: :string,
                description: "Skill name (required for inline entries)."
              },
              content: %Schema{
                type: :string,
                description: "Full SKILL.md body for inline entries."
              },
              source: %Schema{
                type: :string,
                description: "GitHub `owner/repo` for skills.sh-sourced entries.",
                pattern: "^[A-Za-z0-9._/-]+$"
              },
              ref: %Schema{
                type: :string,
                description:
                  "Optional tag, branch, or sha pinning a github-sourced skill " <>
                    "(installed as `owner/repo@ref`). Without it the default branch " <>
                    "is fetched at spawn time.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        allowed_vault_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Vaults a conversation may attach to this agent. null (default) allows " <>
              "any vault the tenant owns; an empty list forbids attaching any vault; " <>
              "a non-empty list is an allowlist."
        },
        # `Agent.changeset/2` has cast this since the allowlist shipped and
        # `AgentUpdate` declares it, but this schema did not — so a client
        # generated from the spec could set the allowlist on PATCH and not on
        # POST, while the endpoint accepted it either way.
        allowed_environment_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Environments a conversation may launch this agent under instead of its " <>
              "own. Same shape as allowed_vault_ids: null (default) allows any " <>
              "environment the tenant owns; an empty list forbids overriding; a " <>
              "non-empty list is an allowlist. The agent's own environment always passes."
        }
      },
      # `model` is required for every runtime but acp, which needs none. A
      # conditional requirement is not expressible here, so the changeset is
      # where it is enforced and a missing model is a 422 rather than a 400.
      required: [:name, :runtime]
    })
  end

  defmodule AgentUpdate do
    require OpenApiSpex

    @moduledoc """
    Partial update — every field is optional. Used by `PUT /api/agents/:id`.
    """

    OpenApiSpex.schema(%{
      title: "AgentUpdate",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string},
        system: %Schema{type: :string},
        # Nullable for the same reason AgentRequest's is: converting an agent
        # to the acp runtime has to be able to clear the model.
        model: %Schema{type: :string, nullable: true, pattern: "^[a-z0-9_-]+/[a-z0-9._-]+$"},
        runtime: %Schema{type: :string, enum: Fountain.Agents.Agent.known_runtimes()},
        runtime_command: %Schema{
          type: :string,
          nullable: true,
          description:
            "The command the acp runtime launches inside the sandbox, as a shell line " <>
              "resolved there (for example `chant acp`). Required when runtime is " <>
              "acp, and rejected on every other runtime, which resolves its own " <>
              "executable. A free string by design: it runs under the same isolation " <>
              "as an environment's setup script."
        },
        sandbox_provider: %Schema{
          type: :string,
          enum: ~w(sprites e2b daytona runner),
          nullable: true,
          description:
            "Sandbox backend override; null inherits the instance default " <>
              "(SANDBOX_PROVIDER). Only providers configured on this instance are accepted"
        },
        sandbox_mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          description:
            "Where a conversation of this agent runs by default (ADR 0023). ephemeral: a " <>
              "sandbox per conversation, reclaimed with it. persistent: one sandbox per " <>
              "agent identity (agent, environment, vault) — the agent's computer — that " <>
              "every conversation of that identity lands on and shares; it survives a " <>
              "conversation ending and is parked, not destroyed, at the ceiling. A launch " <>
              "may name the other with sandbox_mode on POST /api/conversations."
        },
        permission_policy: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            ask_timeout: %Schema{
              type: :integer,
              minimum: 1,
              maximum: Fountain.PermissionPolicy.max_ask_timeout_seconds(),
              description:
                "Seconds a permission request that outlived its turn waits before it " <>
                  "is denied (#1635). Names no tool, so it is the one key whose value " <>
                  "is a number rather than a verdict, which is why the value schema " <>
                  "below is a union. Absent leaves the global ask timeout. A request " <>
                  "may shorten it with `_meta.fountain.timeout` on its own " <>
                  "session/request_permission, and may not lengthen it. A launch may " <>
                  "only shorten what the agent set, or the global ask timeout where " <>
                  "the agent set nothing. Capped at a year, which is where the " <>
                  "deadline stops fitting in a timestamp rather than a limit on how " <>
                  "long a wait is useful."
            }
          },
          additionalProperties: %Schema{
            oneOf: [
              %Schema{type: :string, enum: Managoat.ACP.Permissions.buildable_verdicts()},
              %Schema{type: :integer, minimum: 1}
            ]
          },
          description:
            "Per-tool permission policy: a map of key to verdict, plus an optional " <>
              "\"default\" key. A key is matched against the tool card's title first and " <>
              "then ACP's kind (execute, edit, read, fetch, \u2026); prefer a kind, because " <>
              "claude titles a tool call with the command it is about to run. Unset keys " <>
              "fall back to the default, and an unset default is auto_allow. \"ask\" holds " <>
              "the tool until a human answers it on the conversation stream, and denies if " <>
              "nobody does before the timeout. A conversation may narrow this at launch, " <>
              "never widen it. A runtime that never asks (opencode) refuses anything " <>
              "stricter than auto_allow with 422 permission_policy_unenforceable."
        },
        allowed_environment_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Environments a conversation may launch this agent under instead of its own " <>
              "(environment_id on create). Same shape as allowed_vault_ids: null (default) " <>
              "allows any environment the tenant owns; an empty list forbids overriding; " <>
              "a non-empty list is an allowlist. The agent's own environment always passes."
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        skills: %Schema{
          type: :array,
          description:
            "Each entry is either inline (`{name, content}` — full SKILL.md text written to the sprite) " <>
              "or github (`{source, ref?, name?}` — installed on the sprite via the skills.sh CLI, " <>
              "optionally pinned to a tag/branch/sha via `ref`). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{
                type: :string,
                description: "Skill name (required for inline entries)."
              },
              content: %Schema{
                type: :string,
                description: "Full SKILL.md body for inline entries."
              },
              source: %Schema{
                type: :string,
                description: "GitHub `owner/repo` for skills.sh-sourced entries.",
                pattern: "^[A-Za-z0-9._/-]+$"
              },
              ref: %Schema{
                type: :string,
                description:
                  "Optional tag, branch, or sha pinning a github-sourced skill " <>
                    "(installed as `owner/repo@ref`). Without it the default branch " <>
                    "is fetched at spawn time.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        allowed_vault_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Vaults a conversation may attach to this agent. null (default) allows " <>
              "any vault the tenant owns; an empty list forbids attaching any vault; " <>
              "a non-empty list is an allowlist."
        }
      }
    })
  end

  defmodule Repository do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Repository",
      type: :object,
      properties: %{
        url: %Schema{type: :string, format: :uri, pattern: "^https://"},
        mount_path: %Schema{type: :string, pattern: "^/"},
        # Both are read by `Provisioning.clone_https/4` and neither was
        # declared, so a private repository could not be expressed by a client
        # generated from this spec — and an unauthenticated clone of one fails
        # inside the sandbox rather than at the API.
        secret_key: %Schema{
          type: :string,
          description:
            "Name of a secret — on the environment or on a vault attached at launch — " <>
              "holding a token to clone with. The clone uses it as HTTPS " <>
              "`x-access-token` auth. Required for a private repository; omit it for a " <>
              "public one."
        },
        ref: %Schema{
          type: :string,
          description:
            "Optional branch or tag to clone (`git clone -b`). Without it the default " <>
              "branch is cloned."
        }
      },
      required: [:url, :mount_path]
    })
  end

  defmodule Environment do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Environment",
      description: "A reusable sandbox environment: packages, env vars, repos, networking.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        packages: %Schema{type: :object, additionalProperties: true},
        env_vars: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        setup_script: %Schema{type: :string},
        setup_timeout_seconds: %Schema{
          type: :integer,
          minimum: 1,
          maximum: 900,
          description:
            "Setup exec timeout in seconds; defaults to 120. The overall provisioning deadline still applies."
        },
        networking_type: %Schema{type: :string, enum: ~w(unrestricted limited)},
        networking_config: %Schema{
          type: :object,
          description: networking_config_description(),
          properties: %{
            allowed_hosts: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Domains the sandbox may reach when networking_type is limited."
            }
          },
          additionalProperties: true
        },
        allowed_environment_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Environments a conversation may launch this agent under instead of its own " <>
              "(environment_id on create). Same shape as allowed_vault_ids: null (default) " <>
              "allows any environment the tenant owns; an empty list forbids overriding; " <>
              "a non-empty list is an allowlist. The agent's own environment always passes."
        },
        repositories: %Schema{type: :array, items: Repository},
        metadata: %Schema{type: :object, additionalProperties: true},
        secret_count: %Schema{type: :integer, description: "Secrets stored on this environment."},
        agent_count: %Schema{
          type: :integer,
          description: "Agents referencing this environment — 0 means safe to delete."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name]
    })
  end

  item_response(EnvironmentResponse, of: Environment)

  list_response(EnvironmentListResponse, of: Environment)
  item_response(SandboxResponse, of: SandboxDetail)
  list_response(SandboxListResponse, of: SandboxDetail)
  item_response(SandboxListingResponse, of: SandboxListing)
  item_response(SandboxFileResponse, of: SandboxFile)
  item_response(SandboxDiffResponse, of: SandboxDiff)
  item_response(SandboxStatusResponse, of: SandboxStatus)

  defmodule EnvironmentRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EnvironmentRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        packages: %Schema{type: :object, additionalProperties: true},
        env_vars: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        setup_script: %Schema{type: :string},
        setup_timeout_seconds: %Schema{
          type: :integer,
          minimum: 1,
          maximum: 900,
          description:
            "Setup exec timeout in seconds; defaults to 120. The overall provisioning deadline still applies."
        },
        networking_type: %Schema{type: :string, enum: ~w(unrestricted limited)},
        networking_config: %Schema{
          type: :object,
          description: networking_config_description(),
          properties: %{
            allowed_hosts: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Domains the sandbox may reach when networking_type is limited."
            }
          },
          additionalProperties: true
        },
        repositories: %Schema{type: :array, items: Repository},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      required: [:name]
    })
  end

  defmodule EnvironmentUpdate do
    require OpenApiSpex

    @moduledoc """
    Partial update — every field is optional. The server merges into the
    existing record. Used by `PUT /api/environments/:id`.
    """

    OpenApiSpex.schema(%{
      title: "EnvironmentUpdate",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        packages: %Schema{type: :object, additionalProperties: true},
        env_vars: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        setup_script: %Schema{type: :string},
        setup_timeout_seconds: %Schema{
          type: :integer,
          minimum: 1,
          maximum: 900,
          description:
            "Setup exec timeout in seconds; defaults to 120. The overall provisioning deadline still applies."
        },
        networking_type: %Schema{type: :string, enum: ~w(unrestricted limited)},
        networking_config: %Schema{
          type: :object,
          description: networking_config_description(),
          properties: %{
            allowed_hosts: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Domains the sandbox may reach when networking_type is limited."
            }
          },
          additionalProperties: true
        },
        repositories: %Schema{type: :array, items: Repository},
        metadata: %Schema{type: :object, additionalProperties: true}
      }
    })
  end

  defmodule Secret do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Secret",
      description: "A named secret. Values are write-only — the API never returns them.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        key: %Schema{type: :string},
        environment_id: %Schema{type: :string, format: :uuid},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :key, :environment_id]
    })
  end

  item_response(SecretResponse, of: Secret)

  list_response(SecretListResponse, of: Secret)

  defmodule SecretRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretRequest",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        value: %Schema{type: :string, description: "Secret value (write-only)."}
      },
      required: [:key, :value]
    })
  end

  defmodule Vault do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Vault",
      description:
        "A free-floating bag of env-var overrides selected at conversation creation. " <>
          "Vault values override an environment's baseline secrets when the same key is set on both.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        description: %Schema{type: :string},
        metadata: %Schema{type: :object, additionalProperties: true},
        secret_count: %Schema{type: :integer, description: "Secrets stored in this vault."},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name]
    })
  end

  item_response(VaultResponse, of: Vault)

  list_response(VaultListResponse, of: Vault)

  defmodule VaultRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      required: [:name]
    })
  end

  defmodule VaultUpdate do
    require OpenApiSpex

    @moduledoc """
    Partial update — every field is optional. Used by `PUT /api/vaults/:id`.
    """

    OpenApiSpex.schema(%{
      title: "VaultUpdate",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string},
        metadata: %Schema{type: :object, additionalProperties: true}
      }
    })
  end

  defmodule VaultSecret do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecret",
      description:
        "A named secret in a vault. Values are write-only — the API never returns them.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        key: %Schema{type: :string},
        vault_id: %Schema{type: :string, format: :uuid},
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :key, :vault_id]
    })
  end

  item_response(VaultSecretResponse, of: VaultSecret)

  list_response(VaultSecretListResponse, of: VaultSecret)

  defmodule VaultSecretRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecretRequest",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        value: %Schema{type: :string, description: "Secret value (write-only)."},
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description:
            "When the value stops working, as recorded by the owner. " <>
              "Advisory: the owner is emailed before this instant; nothing is enforced."
        }
      },
      required: [:key, :value]
    })
  end

  defmodule VaultSecretMetadataRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecretMetadataRequest",
      type: :object,
      additionalProperties: false,
      properties: %{
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Advisory expiry. Null clears it; omission keeps the current value."
        }
      }
    })
  end

  defmodule Block do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Block",
      description:
        "One structured piece of a log event's output — the same parse the web UI " <>
          "renders (`Fountain.Conversations.Blocks`). `kind` decides the other fields: " <>
          "`text`/`thinking` carry `body`; `tool_use` carries `id`, `name`, `summary`, " <>
          "`body` (the input); `tool_result` carries `tool_id`, `body`, `error` and pairs " <>
          "with the `tool_use` of the same id; `init` carries `summary`, `body`; `result` " <>
          "carries `body`, `raw`; `error` carries `body`; `raw` carries `body`, `summary`; " <>
          "`permission_request` carries `request_id`, `name`, `summary` and `options` — the " <>
          "agent is blocked on it, and a client answers with " <>
          "POST /api/conversations/{id}/requests/{request_id}. Render only the options in " <>
          "`options`; never synthesise one the agent did not offer.",
      type: :object,
      properties: %{
        kind: %Schema{
          type: :string,
          enum: Fountain.Conversations.Blocks.kinds()
        },
        body: %Schema{type: :string, nullable: true},
        summary: %Schema{type: :string, nullable: true},
        id: %Schema{type: :string, nullable: true},
        name: %Schema{type: :string, nullable: true},
        tool_id: %Schema{type: :string, nullable: true},
        error: %Schema{type: :boolean, nullable: true},
        raw: %Schema{type: :string, nullable: true},
        request_id: %Schema{
          type: :string,
          nullable: true,
          description: "permission_request only: the id to answer with."
        },
        options: %Schema{
          type: :array,
          nullable: true,
          description:
            "permission_request only: the options the agent offered, in its order. " <>
              "Each carries at least `optionId` and `kind` (allow_once, allow_always, " <>
              "reject_once, reject_always, ...).",
          items: %Schema{type: :object, additionalProperties: true}
        }
      },
      required: [:kind],
      additionalProperties: true
    })
  end

  defmodule LogEvent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LogEvent",
      description:
        "One line of a conversation's log feed: runtime output or a lifecycle " <>
          "stage transition. Same fields the SSE stream sends, plus `id`.",
      type: :object,
      properties: %{
        id: %Schema{
          type: :integer,
          description: "Monotonic id. Pagination cursor here, `Last-Event-ID` on the SSE route."
        },
        kind: %Schema{type: :string, enum: ~w(output stage)},
        stream: %Schema{
          type: :string,
          description: "`stdout` / `stderr` for output events; empty for stage events."
        },
        data: %Schema{
          type: :string,
          description: "Output text, or JSON-encoded metadata for stage events."
        },
        stage: %Schema{
          type: :string,
          nullable: true,
          description: "Lifecycle stage name. null on an event that has no stage."
        },
        state: %Schema{
          type: :string,
          enum: ~w(started done failed interrupted),
          nullable: true,
          description: "Lifecycle state of the stage. null on an event that has no state."
        },
        duration_ms: %Schema{type: :integer, nullable: true},
        turn_id: %Schema{type: :string, format: :uuid, nullable: true},
        ts: %Schema{type: :string, format: :"date-time"},
        blocks: %Schema{
          type: :array,
          items: Block,
          description:
            "Only with `?blocks=true`: `data` parsed server-side into the blocks a " <>
              "transcript renders. Empty for non-output events."
        }
      },
      required: [:id, :kind, :ts]
    })
  end

  defmodule LogEventListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LogEventListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: LogEvent},
        meta: %Schema{
          type: :object,
          properties: %{
            limit: %Schema{type: :integer},
            has_more: %Schema{type: :boolean},
            next_cursor: %Schema{
              type: :integer,
              nullable: true,
              description: "Pass as `after` to fetch the next page. null when the page is empty."
            }
          },
          required: [:limit, :has_more]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule AdminUser do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminUser",
      description: "An account as the operator surface sees it. Metadata only.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        email: %Schema{type: :string},
        role: %Schema{type: :string, enum: ~w(admin user)},
        email_verified: %Schema{type: :boolean},
        email_verified_at: %Schema{type: :string, format: :"date-time", nullable: true},
        suspended: %Schema{type: :boolean},
        suspended_at: %Schema{type: :string, format: :"date-time", nullable: true},
        comped: %Schema{
          type: :boolean,
          description: "A free account: the balance is never checked (ADR 0031)."
        },
        has_stripe_customer: %Schema{type: :boolean},
        max_concurrent_sandboxes: %Schema{
          type: :integer,
          nullable: true,
          description:
            "The concurrency cap actually enforced: the override, or the balance rule's."
        },
        sandbox_limit_override: %Schema{
          type: :integer,
          nullable: true,
          description: "Admin override of the cap. Null means the balance rule applies."
        },
        credit_balance_cents: %Schema{
          type: :integer,
          description:
            "Prepaid balance in cents (ADR 0030). May be negative. Zero while credits are not active on this deployment."
        },
        active_sandboxes: %Schema{type: :integer},
        onboarding_completed_at: %Schema{type: :string, format: :"date-time", nullable: true},
        last_activity_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :email, :role]
    })
  end

  item_response(AdminUserResponse, of: AdminUser)

  defmodule AdminUserListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminUserListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: AdminUser},
        meta: %Schema{
          type: :object,
          properties: %{
            page: %Schema{type: :integer},
            per_page: %Schema{type: :integer},
            total: %Schema{type: :integer}
          },
          required: [:page, :per_page, :total]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule AdminRoleRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminRoleRequest",
      type: :object,
      properties: %{role: %Schema{type: :string, enum: ~w(admin user)}},
      required: [:role]
    })
  end

  defmodule AdminSandboxLimitRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminSandboxLimitRequest",
      type: :object,
      properties: %{
        limit: %Schema{
          type: :integer,
          minimum: 0,
          nullable: true,
          description:
            "Override of the balance-funded concurrent-sandbox cap. Null clears it, " <>
              "handing the cap back to the balance rule."
        }
      },
      required: [:limit]
    })
  end

  defmodule AdminCompRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminCompRequest",
      type: :object,
      properties: %{comped: %Schema{type: :boolean}},
      required: [:comped]
    })
  end

  defmodule AdminCreditsRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminCreditsRequest",
      type: :object,
      properties: %{
        cents: %Schema{
          type: :integer,
          minimum: 1,
          description: "Credit to add, in cents. Never expires and is spent last."
        },
        note: %Schema{
          type: :string,
          nullable: true,
          description: "Why, for the audit trail. A won dispute, a goodwill credit, an outage."
        }
      },
      required: [:cents],
      example: %{"cents" => 1000, "note" => "won dispute dp_123"}
    })
  end

  defmodule AdminSuspendRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminSuspendRequest",
      type: :object,
      properties: %{suspended: %Schema{type: :boolean}},
      required: [:suspended]
    })
  end

  defmodule AdminResyncResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminResyncResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            outcome: %Schema{type: :string, enum: ~w(resynced customer_sync_enqueued)},
            comped: %Schema{type: :boolean}
          },
          required: [:outcome]
        }
      },
      required: [:data]
    })
  end

  defmodule AdminSandbox do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminSandbox",
      description: "A live sandbox, cross-tenant. Metadata only — never contents.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        sprite_name: %Schema{type: :string},
        provider: %Schema{type: :string, description: "Sandbox backend that owns this row"},
        status: %Schema{type: :string},
        user_id: %Schema{type: :string, format: :uuid, nullable: true},
        user_email: %Schema{type: :string, nullable: true},
        conversation_count: %Schema{type: :integer},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :status]
    })
  end

  list_response(AdminSandboxListResponse, of: AdminSandbox)

  defmodule AdminReapResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminReapResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            sandbox_id: %Schema{type: :string, format: :uuid},
            outcome: %Schema{type: :string, enum: ~w(terminated released already_terminal)}
          },
          required: [:outcome]
        }
      },
      required: [:data]
    })
  end

  # Fully qualified: AuditEvent is defined further down this file, and the
  # implicit alias a nested defmodule creates only exists after it.
  list_response(AdminAuditListResponse,
    of: FountainWeb.Schemas.AuditEvent,
    description: "Cross-tenant audit events; each carries the tenant it belongs to."
  )

  defmodule AdminEventListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminEventListResponse",
      description: "The privilege trail: who did what to whom.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :integer},
              inserted_at: %Schema{type: :string, format: :"date-time"},
              event_type: %Schema{type: :string, example: "admin.account.suspended"},
              actor_user_id: %Schema{type: :string, format: :uuid, nullable: true},
              target_user_id: %Schema{type: :string, format: :uuid, nullable: true},
              metadata: %Schema{type: :object, additionalProperties: true}
            },
            required: [:event_type]
          }
        }
      },
      required: [:data]
    })
  end

  defmodule BillingResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BillingResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            sandbox_cap: %Schema{
              type: :integer,
              description:
                "How many sandboxes this account may run at once: an admin override, " <>
                  "or what the balance funds (ADR 0031)."
            },
            has_stripe_customer: %Schema{type: :boolean},
            period: %Schema{
              type: :object,
              description:
                "The calendar month the usage numbers cover, half-open: `end` is " <>
                  "the first instant of the next month.",
              properties: %{
                start: %Schema{type: :string, format: :"date-time"},
                end: %Schema{type: :string, format: :"date-time"}
              }
            },
            credits: %Schema{
              type: :object,
              nullable: true,
              description:
                "The prepaid balance, in cents. Null when this deployment has " <>
                  "billing off; a client must not show a zero balance then. " <>
                  "At zero, new work is refused with 402 `insufficient_credits`.",
              properties: %{
                balance_cents: %Schema{
                  type: :integer,
                  description: "May be negative: an in-flight turn that crosses zero finishes."
                },
                expiring_cents: %Schema{
                  type: :integer,
                  description:
                    "Unspent credit from the earliest live grant, which expires at expires_at."
                },
                expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
                purchased_cents: %Schema{
                  type: :integer,
                  description:
                    "The part of the balance that was bought. It never expires and is spent last."
                },
                turn_hour_cents: %Schema{
                  type: :integer,
                  description: "What one hour of turn time costs."
                },
                packs_cents: %Schema{
                  type: :array,
                  items: %Schema{type: :integer},
                  description: "The packs on sale, ascending. Pass one to the credits checkout."
                }
              }
            },
            usage: %Schema{
              type: :object,
              properties: %{
                conversations: %Schema{
                  type: :integer,
                  description: "Conversations that ran a turn in the month, deleted or not."
                },
                turns: %Schema{type: :integer},
                credit_burned_cents: %Schema{
                  type: :integer,
                  nullable: true,
                  description:
                    "Cents the ledger took this month: turns, rent and messages. " <>
                      "The charged number, where turn_hours is the metered one. " <>
                      "Null with billing off."
                },
                turn_hours: %Schema{
                  type: :number,
                  description:
                    "Hours with a prompt in flight, on providers Fountain pays " <>
                      "for; what burns credit. An idle sandbox spends none of " <>
                      "these; sandbox_minutes counts it."
                },
                sandbox_minutes: %Schema{
                  type: :number,
                  description: "Active sandbox minutes inside the period, parked time excluded."
                },
                sandbox_minutes_by_provider: %Schema{
                  type: :object,
                  description:
                    "sandbox_minutes split by sandbox provider (sprites, e2b, " <>
                      "daytona, runner). Providers not used in the period are absent.",
                  additionalProperties: %Schema{type: :number}
                }
              }
            }
          },
          required: [:usage]
        }
      },
      required: [:data]
    })
  end

  defmodule CreditsCheckoutRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CreditsCheckoutRequest",
      type: :object,
      properties: %{
        cents: %Schema{
          type: :integer,
          description: "The pack to buy, in cents. Must be one of credits.packs_cents."
        }
      },
      required: [:cents],
      example: %{"cents" => 2500}
    })
  end

  defmodule StripeUrlResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StripeUrlResponse",
      description: "A Stripe-hosted URL to open in a browser. Single-use and short-lived.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{url: %Schema{type: :string, format: :uri}},
          required: [:url]
        }
      },
      required: [:data]
    })
  end

  defmodule Export do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Export",
      description:
        "An account data export. Built asynchronously; the payload is fetched " <>
          "from the download endpoint, never embedded here.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: ~w(pending completed failed)},
        byte_size: %Schema{type: :integer, nullable: true, description: "Uncompressed size."},
        error: %Schema{type: :string, nullable: true},
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
        downloadable: %Schema{
          type: :boolean,
          description: "Completed and not yet expired — the only state the download serves."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :status]
    })
  end

  item_response(ExportResponse, of: Export)

  list_response(ExportListResponse, of: Export)

  defmodule AccountDeleteRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AccountDeleteRequest",
      type: :object,
      properties: %{
        confirm: %Schema{
          type: :string,
          description: "The account's own email address, exactly."
        }
      },
      required: [:confirm]
    })
  end

  defmodule AccountDeletedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AccountDeletedResponse",
      type: :object,
      properties: %{
        deleted: %Schema{type: :boolean},
        user_id: %Schema{type: :string, format: :uuid},
        sprites_destroyed: %Schema{type: :integer}
      },
      required: [:deleted]
    })
  end

  defmodule AvatarRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AvatarRequest",
      description:
        "JSON form of an avatar upload. The raw-bytes form sends the image " <>
          "directly with an image content-type instead.",
      type: :object,
      properties: %{
        data: %Schema{type: :string, description: "Base64-encoded image bytes."},
        media_type: %Schema{
          type: :string,
          enum: ~w(image/png image/jpeg image/gif image/webp)
        }
      },
      required: [:data, :media_type]
    })
  end

  defmodule OnboardingResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OnboardingResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            completed: %Schema{type: :boolean},
            completed_at: %Schema{type: :string, format: :"date-time", nullable: true}
          },
          required: [:completed]
        }
      },
      required: [:data]
    })
  end

  defmodule AuditEvent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuditEvent",
      description: "One entry in the account's append-only audit trail.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Cursor for `before`."},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        actor: %Schema{
          type: :string,
          nullable: true,
          description:
            "Which surface acted: `ui` (browser session), `api` (bearer key), " <>
              "`sprite` (a per-conversation token held by a sandbox), `system`."
        },
        action: %Schema{type: :string, example: "vault.secret.write"},
        resource_type: %Schema{type: :string, nullable: true},
        resource_id: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        request_ip: %Schema{type: :string, nullable: true}
      },
      required: [:id, :action, :inserted_at]
    })
  end

  defmodule AuditEventListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuditEventListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: AuditEvent},
        meta: %Schema{
          type: :object,
          properties: %{
            limit: %Schema{type: :integer},
            has_more: %Schema{type: :boolean},
            next_cursor: %Schema{
              type: :integer,
              nullable: true,
              description: "Pass as `before` for the next (older) page."
            }
          },
          required: [:limit, :has_more]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule InferenceCredentialStatus do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InferenceCredentialStatus",
      description:
        "Whether a provider credential is set for the tenant. Values are " <>
          "write-only — the API never returns a credential, truncated or otherwise.",
      type: :object,
      properties: %{
        provider: %Schema{
          type: :string,
          enum: ~w(anthropic_api_key claude_code_oauth_token openai_api_key gemini_api_key)
        },
        set: %Schema{type: :boolean}
      },
      required: [:provider, :set]
    })
  end

  item_response(InferenceCredentialResponse, of: InferenceCredentialStatus)

  list_response(InferenceCredentialListResponse, of: InferenceCredentialStatus)

  defmodule InferenceCredentialRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InferenceCredentialRequest",
      type: :object,
      properties: %{
        value: %Schema{
          type: :string,
          description: "The provider token (write-only)."
        },
        validate: %Schema{
          type: :boolean,
          default: true,
          description:
            "Ping the provider to check the credential before storing it. " <>
              "false stores it unchecked."
        }
      },
      required: [:value]
    })
  end

  defmodule HealthResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HealthResponse",
      type: :object,
      properties: %{status: %Schema{type: :string, example: "ok"}},
      required: [:status]
    })
  end

  defmodule ReadinessResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ReadinessResponse",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: ["ok", "error"], example: "ok"},
        checks: %Schema{
          type: :object,
          description: "Per-dependency result. `ok` or `error`, with no further detail.",
          additionalProperties: %Schema{type: :string, enum: ["ok", "error"]},
          example: %{"database" => "ok", "broker_listener" => "ok"}
        }
      },
      required: [:status, :checks]
    })
  end

  defmodule TeammateContact do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeammateContact",
      description:
        "A teammate's own email address and phone number, provisioned by Fountain " <>
          "(AgentMail + AgentPhone) behind the `team_comms` flag. The teammate reaches " <>
          "both through MCP tools Fountain serves; no provider key enters its sandbox.",
      type: :object,
      properties: %{
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true, description: "E.164"},
        prompt_from_number: %Schema{
          type: :string,
          nullable: true,
          description:
            "E.164. The one number whose texts to `phone` arrive as prompts in the " <>
              "teammate's conversation; texts from anyone else are ignored."
        },
        prompt_opted_out_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description:
            "Set when `prompt_from_number` texted STOP: its texts are dropped until it texts " <>
              "START, or until the number is changed (new consent)."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:email, :phone]
    })
  end

  defmodule TeamContactRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeamContactRequest",
      type: :object,
      properties: %{
        prompt_from_number: %Schema{
          type: :string,
          description:
            "Your phone number: texts from it to the teammate's new number become prompts " <>
              "in its conversation. Any common format; stored E.164. Required."
        }
      },
      required: [:prompt_from_number]
    })
  end

  defmodule Teammate do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Teammate",
      description:
        "One agent on the team: the agent, its current team conversation (the newest " <>
          "live one, else the newest finished one), and what the roster shows for it.",
      type: :object,
      properties: %{
        agent_id: %Schema{type: :string, format: :uuid},
        name: %Schema{
          type: :string,
          description:
            "What the teammate is called: the conversation's title, else the agent's name."
        },
        agent: Agent,
        conversation: Conversation,
        presence: %Schema{
          type: :object,
          properties: %{
            state: %Schema{type: :string, enum: FountainWeb.TeamPresenter.presence_states()},
            label: %Schema{type: :string}
          },
          required: [:state, :label]
        },
        unread: %Schema{type: :boolean},
        usage_total: %Schema{
          allOf: [UsageTotal],
          description:
            "Summed over every conversation this agent has had under the team " <>
              "channel, not just the current one — the per-teammate figure."
        },
        last_turn: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            turn_number: %Schema{type: :integer},
            prompt: %Schema{type: :string},
            status: %Schema{type: :string},
            inserted_at: %Schema{type: :string, format: :"date-time"},
            usage: %Schema{oneOf: [TurnUsage], nullable: true}
          }
        },
        preview: %Schema{
          type: :object,
          nullable: true,
          description:
            "The roster line: `you` (the last prompt, no reply yet), `them` (the last " <>
              "reply), or `typing` (a turn is in flight). Null with no messages.",
          properties: %{
            kind: %Schema{type: :string, enum: FountainWeb.TeamPresenter.preview_kinds()},
            text: %Schema{type: :string, nullable: true}
          }
        },
        contact: %Schema{
          allOf: [TeammateContact],
          nullable: true,
          description:
            "The teammate's own email address and phone number (flag `team_comms`), " <>
              "or null when it has none."
        }
      },
      required: [:agent_id, :name, :agent, :conversation, :presence, :unread]
    })
  end

  item_response(TeammateResponse, of: Teammate)
  list_response(TeammateListResponse, of: Teammate)

  defmodule TeamCommsStatus do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeamCommsStatus",
      description:
        "Whether teammates can be given an email address and phone number here: `enabled` " <>
          "is the per-user feature flag (`team_comms`), `configured` whether this instance " <>
          "has the provider keys. Both must hold to provision.",
      type: :object,
      properties: %{
        enabled: %Schema{type: :boolean},
        configured: %Schema{type: :boolean}
      },
      required: [:enabled, :configured]
    })
  end

  item_response(TeamCommsStatusResponse, of: TeamCommsStatus)

  defmodule TeamAddRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeamAddRequest",
      type: :object,
      properties: %{
        agent_id: %Schema{type: :string, format: :uuid},
        name: %Schema{
          type: :string,
          nullable: true,
          maxLength: 120,
          description: "What to call the teammate. Blank means the agent's name."
        },
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Provision the teammate's computer from this environment instead of the " <>
              "agent's own. Must satisfy the agent's allowed_environment_ids."
        },
        vault_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Layer this vault's secrets on top. Must satisfy allowed_vault_ids."
        }
      },
      required: [:agent_id]
    })
  end

  defmodule TeamRenameRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeamRenameRequest",
      type: :object,
      properties: %{
        name: %Schema{
          type: :string,
          nullable: true,
          maxLength: 120,
          description: "What to call the teammate. Null or blank means the agent's name."
        }
      }
    })
  end

  defmodule TeammateConversation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeammateConversation",
      description: "A conversation object plus `current`: whether it is the teammate's live one.",
      allOf: [
        Conversation,
        %Schema{
          type: :object,
          properties: %{current: %Schema{type: :boolean}},
          required: [:current]
        }
      ]
    })
  end

  list_response(TeammateConversationListResponse, of: TeammateConversation)

  defmodule TeamMessageRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeamMessageRequest",
      type: :object,
      properties: %{
        prompt: %Schema{type: :string},
        images: %Schema{type: :array, items: ImageInput, nullable: true},
        labels: %Schema{
          type: :object,
          nullable: true,
          additionalProperties: %Schema{type: :string, nullable: true},
          description:
            "Labels to merge into the conversation this message lands on, whether that is " <>
              "the teammate's current one or the fresh one a retired thread is replaced by. " <>
              "Same limits as everywhere else; null removes a key."
        }
      },
      required: [:prompt]
    })
  end

  defmodule TeamMessageResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeamMessageResponse",
      type: :object,
      properties: %{
        status: %Schema{type: :string, example: "queued"},
        conversation_id: %Schema{
          type: :string,
          format: :uuid,
          description:
            "The conversation the message went to — a fresh one when the teammate's " <>
              "previous conversation was past resuming."
        }
      },
      required: [:status, :conversation_id]
    })
  end

  defmodule TeamSchedule do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeamSchedule",
      description:
        "A scheduled prompt for a teammate: on `cron` (five fields, UTC), send `prompt` " <>
          "to the agent — into its team conversation, or (`one_off`) on a fresh computer.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        agent_id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string, nullable: true, maxLength: 120},
        cron: %Schema{type: :string, example: "0 9 * * 1-5"},
        prompt: %Schema{type: :string},
        one_off: %Schema{
          type: :boolean,
          description:
            "false: the prompt goes into the teammate's own conversation. true: each " <>
              "run opens a fresh conversation with the teammate's agent, environment and vault."
        },
        enabled: %Schema{type: :boolean},
        next_run_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "The next fire time (UTC); null while disabled."
        },
        last_run_at: %Schema{type: :string, format: :"date-time", nullable: true},
        last_conversation_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "The conversation the last run went to; null when it failed or never ran."
        },
        last_error: %Schema{
          type: :string,
          nullable: true,
          description:
            "Why the last run did not go out (`teammate was busy`, ...); null after a good run."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :agent_id, :cron, :prompt, :one_off, :enabled]
    })
  end

  item_response(TeamScheduleResponse, of: TeamSchedule)
  list_response(TeamScheduleListResponse, of: TeamSchedule)

  defmodule TeamScheduleCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeamScheduleCreateRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, nullable: true, maxLength: 120},
        cron: %Schema{
          type: :string,
          description: "Five fields, UTC. `@daily`-style names work; `@reboot` does not.",
          example: "0 9 * * 1-5"
        },
        prompt: %Schema{type: :string, minLength: 1, maxLength: 20_000},
        one_off: %Schema{type: :boolean, default: false},
        enabled: %Schema{type: :boolean, default: true}
      },
      required: [:cron, :prompt]
    })
  end

  defmodule TeamScheduleUpdateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TeamScheduleUpdateRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, nullable: true, maxLength: 120},
        cron: %Schema{type: :string, example: "0 9 * * 1-5"},
        prompt: %Schema{type: :string, minLength: 1, maxLength: 20_000},
        one_off: %Schema{type: :boolean},
        enabled: %Schema{type: :boolean}
      }
    })
  end

  defmodule SearchHit do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SearchHit",
      description: "One search hit: what matched, and where to jump.",
      type: :object,
      properties: %{
        kind: %Schema{type: :string, enum: Fountain.Search.kinds()},
        conversation_id: %Schema{type: :string, format: :uuid},
        agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        turn_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "The turn (prompt / reply hits); null for a title hit."
        },
        turn_number: %Schema{type: :integer, nullable: true},
        snippet: %Schema{
          type: :string,
          description: "The best-matching fragment, plain text — no markup to escape."
        },
        ts: %Schema{
          type: :string,
          format: :"date-time",
          description: "The turn's creation time, or the conversation's for a title hit."
        }
      },
      required: [:kind, :conversation_id, :snippet, :ts]
    })
  end

  defmodule SearchResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SearchResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: SearchHit},
        meta: %Schema{
          type: :object,
          properties: %{
            limit: %Schema{type: :integer},
            offset: %Schema{type: :integer},
            has_more: %Schema{type: :boolean}
          },
          required: [:limit, :offset, :has_more]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule CatalogResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CatalogResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            sandbox_api_access: %Schema{
              type: :array,
              items: %Schema{type: :string, enum: ~w(owner none)}
            },
            runtimes: %Schema{type: :array, items: %Schema{type: :string}},
            models: %Schema{
              type: :object,
              additionalProperties: %Schema{type: :array, items: %Schema{type: :string}},
              description:
                "Suggested `provider/model` ids per runtime. Suggestions, not an allowlist."
            },
            model_providers: %Schema{type: :array, items: %Schema{type: :string}},
            sandbox_providers: %Schema{
              type: :object,
              properties: %{
                enabled: %Schema{type: :array, items: %Schema{type: :string}},
                default: %Schema{type: :string}
              },
              required: [:enabled, :default]
            },
            package_managers: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "The managers provisioning installs from an environment's `packages`."
            },
            avatar: %Schema{
              type: :object,
              properties: %{
                bases: %Schema{type: :array, items: %Schema{type: :string}},
                moods: %Schema{type: :array, items: %Schema{type: :string}}
              },
              required: [:bases, :moods]
            },
            apps: %Schema{
              type: :object,
              description:
                "Where this instance sends a human to watch a conversation or " <>
                  "message a teammate. Null for an app this deployment does not have.",
              properties: %{
                conversations: %Schema{type: :string, nullable: true},
                team: %Schema{type: :string, nullable: true}
              },
              required: [:conversations, :team]
            },
            mcp_servers: %Schema{
              type: :array,
              description:
                "Remote MCP servers verified to complete the MCP authorization " <>
                  "discovery chain, each with the date it was last verified. " <>
                  "Suggestions, not an allowlist — any URL can be discovered.",
              items: %Schema{
                type: :object,
                properties: %{
                  slug: %Schema{type: :string},
                  name: %Schema{type: :string},
                  url: %Schema{type: :string},
                  dcr: %Schema{
                    type: :boolean,
                    description:
                      "Whether the authorization server offers dynamic client " <>
                        "registration (RFC 7591). False means the tenant pastes a " <>
                        "client id from their own app registration."
                  },
                  verified_on: %Schema{type: :string, format: :date}
                },
                required: [:slug, :name, :url, :dcr, :verified_on]
              }
            },
            first_request: %Schema{
              type: :object,
              description:
                "The one onboarding request this deployment hands out (ADR 0038), " <>
                  "the same text the verified landing and the manual print. The base " <>
                  "URL is already in it. The caller's key and agent are not: the " <>
                  "server stores only a hash of a key, so a client substitutes the " <>
                  "key it holds and an agent from `GET /api/agents`.",
              properties: %{
                curl: %Schema{type: :string, description: "The `curl`, with placeholders."},
                typescript: %Schema{
                  type: :string,
                  description: "The TypeScript SDK equivalent, with placeholders."
                },
                prompt: %Schema{
                  type: :string,
                  description: "The prompt both snippets send, for a client that runs it."
                },
                placeholders: %Schema{
                  type: :array,
                  items: %Schema{type: :string},
                  description: "Every token a client must substitute before it runs the request."
                }
              },
              required: [:curl, :typescript, :prompt, :placeholders]
            }
          },
          required: [
            :runtimes,
            :models,
            :sandbox_providers,
            :package_managers,
            :avatar,
            :apps,
            :first_request
          ]
        }
      },
      required: [:data]
    })
  end

  defmodule AvatarGenerateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AvatarGenerateRequest",
      type: :object,
      properties: %{
        base: %Schema{type: :string, description: "One of `GET /api/catalog` `avatar.bases`."},
        mood: %Schema{type: :string, description: "One of `GET /api/catalog` `avatar.moods`."}
      },
      required: [:base, :mood]
    })
  end

  defmodule AvatarGenerateResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AvatarGenerateResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            data: %Schema{type: :string, description: "Base64 PNG bytes."},
            media_type: %Schema{type: :string, example: "image/png"}
          },
          required: [:data, :media_type]
        }
      },
      required: [:data]
    })
  end

  defmodule OAuthTokenRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OAuthTokenRequest",
      type: :object,
      properties: %{
        grant_type: %Schema{
          type: :string,
          description: "`authorization_code` (anything else is 400 `unsupported_grant_type`)."
        },
        code: %Schema{
          type: :string,
          description: "The code from the `/oauth/authorize` redirect."
        },
        code_verifier: %Schema{
          type: :string,
          description: "The PKCE verifier whose S256 challenge was sent to `/oauth/authorize`."
        },
        client_id: %Schema{type: :string},
        redirect_uri: %Schema{
          type: :string,
          description: "Exactly the redirect_uri the authorization request used."
        }
      },
      required: [:grant_type, :code, :code_verifier, :client_id, :redirect_uri]
    })
  end

  defmodule OAuthTokenResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OAuthTokenResponse",
      type: :object,
      properties: %{
        access_token: %Schema{
          type: :string,
          description: "A Fountain API key; use it as the bearer token."
        },
        token_type: %Schema{type: :string, example: "bearer"},
        expires_in: %Schema{type: :integer, description: "Seconds until the key expires."}
      },
      required: [:access_token, :token_type, :expires_in]
    })
  end

  defmodule DeviceAuthResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceAuthResponse",
      description:
        "A fresh device-authorization grant (#1305). `device_code` stays on the " <>
          "polling machine and never gets typed; `user_code` is what the human " <>
          "enters at `verification_uri`.",
      type: :object,
      properties: %{
        device_code: %Schema{
          type: :string,
          description: "High-entropy code the CLI polls the token endpoint with. Shown once."
        },
        user_code: %Schema{
          type: :string,
          example: "BCDF-GHJK",
          description: "Short code for the human to type into the console."
        },
        verification_uri: %Schema{
          type: :string,
          description: "The console page where the user approves the grant."
        },
        verification_uri_complete: %Schema{
          type: :string,
          description: "`verification_uri` with the user code prefilled."
        },
        expires_in: %Schema{type: :integer, description: "Seconds until the grant expires."},
        interval: %Schema{
          type: :integer,
          description: "Minimum seconds between polls; faster gets `slow_down`."
        }
      },
      required: [
        :device_code,
        :user_code,
        :verification_uri,
        :verification_uri_complete,
        :expires_in,
        :interval
      ]
    })
  end

  defmodule DeviceTokenRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceTokenRequest",
      type: :object,
      properties: %{
        device_code: %Schema{
          type: :string,
          description: "The `device_code` from `POST /api/auth/device`."
        }
      },
      required: [:device_code]
    })
  end

  defmodule WebhookEndpoint do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookEndpoint",
      description:
        "A URL of yours that Fountain POSTs lifecycle events to. The signing secret is " <>
          "returned only by create and rotate, and never appears here.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        url: %Schema{type: :string, example: "https://example.com/hooks/fountain"},
        description: %Schema{type: :string, nullable: true, maxLength: 500},
        event_types: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "What this endpoint is subscribed to. An exact type " <>
              "(`conversation.turn.done`), one stage (`conversation.turn.*`), or `*` for " <>
              "everything. `GET /api/catalog` is not the source for these; the docs page is.",
          example: ["conversation.turn.done", "conversation.turn.failed"]
        },
        status: %Schema{
          type: :string,
          enum: ["active", "disabled"],
          description:
            "`disabled` means Fountain stopped delivering, either because you switched it " <>
              "off or because deliveries failed for long enough."
        },
        consecutive_failures: %Schema{
          type: :integer,
          description:
            "Events in a row that exhausted their retries. Any accepted delivery clears it."
        },
        disabled_at: %Schema{type: :string, format: :"date-time", nullable: true},
        disabled_reason: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :url, :event_types, :status]
    })
  end

  item_response(WebhookEndpointResponse, of: WebhookEndpoint)
  list_response(WebhookEndpointListResponse, of: WebhookEndpoint)

  defmodule WebhookEndpointCreatedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookEndpointCreatedResponse",
      description:
        "The endpoint, plus the signing secret. This is the only response that carries " <>
          "the secret; it is not recoverable afterwards, only replaceable.",
      type: :object,
      properties: %{
        data: WebhookEndpoint,
        secret: %Schema{
          type: :string,
          description: "The HMAC-SHA256 signing secret. Store it; it is not shown again.",
          example: "whsec_Zm91bnRhaW4tZXhhbXBsZS1zZWNyZXQtdmFsdWU"
        }
      },
      required: [:data, :secret]
    })
  end

  defmodule WebhookEndpointCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookEndpointCreateRequest",
      type: :object,
      properties: %{
        url: %Schema{
          type: :string,
          description:
            "https:// only, unless the instance permits http. Loopback, link-local " <>
              "(including the cloud metadata address) and RFC1918 targets are refused, " <>
              "at request time as well as here.",
          example: "https://example.com/hooks/fountain"
        },
        description: %Schema{type: :string, nullable: true, maxLength: 500},
        event_types: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "Defaults to conversation.turn.done, conversation.turn.failed and " <>
              "conversation.provision.failed when absent.",
          example: ["conversation.turn.done"]
        }
      },
      required: [:url]
    })
  end

  defmodule WebhookEndpointUpdateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookEndpointUpdateRequest",
      description: "Any subset. `status` toggles delivery; the secret is rotated separately.",
      type: :object,
      properties: %{
        url: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true, maxLength: 500},
        event_types: %Schema{type: :array, items: %Schema{type: :string}},
        status: %Schema{type: :string, enum: ["active", "disabled"]}
      }
    })
  end

  defmodule WebhookDelivery do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookDelivery",
      description: "One HTTP attempt at one event. Retained for 30 days by default, then pruned.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        event_id: %Schema{
          type: :string,
          description: "The log_events row id, which is also the SSE event id."
        },
        event_type: %Schema{type: :string, example: "conversation.turn.done"},
        attempt: %Schema{type: :integer, description: "1 for the first try."},
        status_code: %Schema{
          type: :integer,
          nullable: true,
          description: "null when the request never got a response."
        },
        duration_ms: %Schema{type: :integer, nullable: true},
        error: %Schema{type: :string, nullable: true},
        response_body: %Schema{
          type: :string,
          nullable: true,
          description: "The first few KB of what the receiver said."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :event_id, :event_type, :attempt]
    })
  end

  list_response(WebhookDeliveryListResponse, of: WebhookDelivery)

  defmodule WebhookTestResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "WebhookTestResponse",
      description:
        "The test event was queued. Its delivery shows up in " <>
          "`GET /api/webhooks/{id}/deliveries` once the worker has run.",
      type: :object,
      properties: %{
        queued: %Schema{type: :boolean},
        event_type: %Schema{type: :string, example: "webhook.test"}
      },
      required: [:queued, :event_type]
    })
  end

  defmodule Error do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Error",
      type: :object,
      properties: %{error: %Schema{type: :string}},
      required: [:error]
    })
  end

  defmodule BrokerUnavailableError do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BrokerUnavailableError",
      description: "The egress broker did not answer the request log call.",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "Always `broker_unavailable`."},
        message: %Schema{type: :string, description: "A sentence for a human."},
        reason: %Schema{
          type: :string,
          description:
            "A stable word for a client to branch on: `econnrefused`, `timeout`, " <>
              "`nxdomain`, `api_error_<status>`, or `unknown`. The detail is in " <>
              "the server log, not here."
        }
      },
      required: [:error, :message, :reason]
    })
  end

  defmodule ManifestResource do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ManifestResource",
      description:
        "One compiled document from a fountain.yml manifest. `spec` matches the " <>
          "create/update schema for the kind, plus an inline `secrets` map " <>
          "(Environment and Vault). Specs reference other documents by name, and " <>
          "the server resolves each to an id: an Agent's `environment`, a " <>
          "Teammate's `agent`, `environment` and `vault`, and a Schedule's " <>
          "`teammate`. Teammate specs take `agent`, `environment` and `vault`, " <>
          "and a Teammate document is read as a whole declaration, so an absent " <>
          "`environment` or `vault` clears that binding. Schedule specs take " <>
          "`teammate` plus the TeamScheduleCreateRequest fields `cron`, " <>
          "`prompt`, `one_off` and `enabled`; Webhook specs take the " <>
          "WebhookEndpointCreateRequest fields `url`, `description` and " <>
          "`event_types`, and are keyed by `url` rather than by `name`.",
      type: :object,
      properties: %{
        kind: %Schema{
          type: :string,
          enum: ["Environment", "Vault", "Agent", "Teammate", "Schedule", "Webhook"]
        },
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        spec: %Schema{type: :object, additionalProperties: true}
      },
      required: [:kind, :name]
    })
  end

  defmodule ApplyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplyRequest",
      type: :object,
      properties: %{
        resources: %Schema{type: :array, items: ManifestResource}
      },
      required: [:resources]
    })
  end

  defmodule ApplySecretResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplySecretResult",
      description: "Outcome for one secret key. Values are never echoed back.",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        action: %Schema{type: :string, enum: ["upserted", "error"]},
        errors: %Schema{type: :object, additionalProperties: true, nullable: true}
      },
      required: [:key, :action]
    })
  end

  defmodule ApplyResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplyResult",
      type: :object,
      properties: %{
        kind: %Schema{type: :string},
        name: %Schema{type: :string},
        action: %Schema{
          type: :string,
          enum: ["created", "updated", "unchanged", "error"],
          description:
            "`unchanged` means the record already matched the document, so nothing " <>
              "was written to it and no audit event was recorded. Inline " <>
              "`spec.secrets` are re-encrypted on every apply and still report " <>
              "`upserted` under `secrets`."
        },
        errors: %Schema{type: :object, additionalProperties: true, nullable: true},
        secrets: %Schema{type: :array, items: ApplySecretResult},
        secret: %Schema{
          type: :string,
          nullable: true,
          description:
            "A Webhook endpoint's HMAC-SHA256 signing secret, on the apply that " <>
              "created it. Store it; it is not shown again, and an update never " <>
              "returns it. Null on every other row.",
          example: "whsec_Zm91bnRhaW4tZXhhbXBsZS1zZWNyZXQtdmFsdWU"
        }
      },
      required: [:kind, :name, :action]
    })
  end

  defmodule ApplyResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplyResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{results: %Schema{type: :array, items: ApplyResult}},
          required: [:results]
        }
      },
      required: [:data]
    })
  end

  defmodule ChangesetError do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChangesetError",
      description:
        "Validation errors keyed by field, with each value an array of messages, " <>
          "beside the code every Fountain error carries.",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
        },
        # Always `validation_failed` on this body, and always present since
        # #1431 — a 422 is not always a validation failure (the fallback
        # controller renders coded refusals with the same status), so a client
        # that branches on the code needs one here too. Keep this schema
        # compatible; mixed refusals use UnprocessableEntityError.
        error: %Schema{type: :string, description: "`validation_failed`."}
      },
      required: [:errors]
    })
  end

  defmodule UnprocessableEntityError do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UnprocessableEntityError",
      description:
        "A rejected request. Field validation failures include errors; " <>
          "other refusals carry an error and may include a message.",
      type: :object,
      properties: %{
        error: %Schema{type: :string},
        message: %Schema{type: :string},
        errors: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
        }
      },
      required: [:error]
    })
  end

  ## ─── Auth (#571) ───────────────────────────────────────────────────────────
  #
  # The `/api/auth/*` surface. Errors here carry a machine-readable `error`
  # alongside the prose `message`, which the resource endpoints' plain
  # `Schemas.Error` does not — a client retrying a reset needs to tell
  # `expired` from `invalid_token` without parsing English.

  defmodule AuthError do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthError",
      description: "An auth failure with a stable reason code.",
      type: :object,
      properties: %{
        error: %Schema{
          type: :string,
          description:
            "Reason code, e.g. `expired`, `invalid_token`, `invalid_current_password`.",
          example: "invalid_token"
        },
        message: %Schema{type: :string, description: "Human-readable detail."}
      },
      required: [:error]
    })
  end

  defmodule MessageResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MessageResponse",
      type: :object,
      properties: %{message: %Schema{type: :string}},
      required: [:message]
    })
  end

  defmodule AuthTokenRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthTokenRequest",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email},
        password: %Schema{type: :string, format: :password}
      },
      required: [:email, :password]
    })
  end

  defmodule AuthTokenResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthTokenResponse",
      description: "A freshly minted full-scope key. `api_key` is shown once and never again.",
      type: :object,
      properties: %{
        api_key: %Schema{type: :string, example: "ftn_live_..."},
        key_id: %Schema{type: :string, format: :uuid},
        prefix: %Schema{
          type: :string,
          description: "Leading characters of the key, the only part stored in the clear."
        }
      },
      required: [:api_key, :key_id, :prefix]
    })
  end

  defmodule AuthMeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthMeResponse",
      description: "Identity of the account the bearer token belongs to.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        email: %Schema{type: :string, format: :email},
        role: %Schema{type: :string, enum: ~w(user admin)},
        email_verified: %Schema{type: :boolean},
        onboarding_completed: %Schema{type: :boolean},
        comped: %Schema{type: :boolean, nullable: true, description: "Null when billing is off."},
        brokered: %Schema{
          type: :boolean,
          description:
            "Whether this account's conversations run behind the egress credential " <>
              "broker (ADR 0019): secrets with bindings stay at the broker, a limited " <>
              "environment is enforced there, and /api/conversations/:id/egress " <>
              "has content. Connections availability is separate. Read-only; an operator " <>
              "sets it."
        },
        connections_enabled: %Schema{
          type: :boolean,
          description:
            "Whether Connections and credential binding management are enabled for this account."
        },
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      # These four are what `show/2` always renders. The list used to read
      # [:id, :name, :prefix, :created_at] — copied from ApiKey below, naming
      # three properties this schema does not have. Nothing caught it because
      # openapi-typescript drops a required name with no property, so the
      # generated client just had every field optional. The SDK contract
      # projection refuses to build such a schema, which is how it surfaced.
      required: [:id, :email, :role, :email_verified]
    })
  end

  defmodule ApiKey do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKey",
      description: "Key metadata. Never the key itself, and never its hash.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        prefix: %Schema{type: :string},
        created_at: %Schema{type: :string, format: :"date-time"},
        last_used_at: %Schema{type: :string, format: :"date-time", nullable: true},
        scopes: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "`full` for a key a person minted; `sprite:<conversation_id>` for the " <>
              "auto-issued token a sandbox holds."
        },
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:id, :name, :prefix, :created_at]
    })
  end

  # ApiKey is referenced by the implicit alias the nested defmodule above
  # created; it only exists after that definition, hence the ordering.
  list_response(ApiKeyListResponse, of: ApiKey)

  defmodule OAuthClient do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OAuthClient",
      description:
        "A tenant-owned OAuth client. Unpublished clients are in development " <>
          "mode and can sign in only their owner. Their redirect origins are " <>
          "also admitted by CORS.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        client_id: %Schema{
          type: :string,
          description: "The client_id sent to /oauth/authorize."
        },
        name: %Schema{type: :string, description: "Shown on the consent page."},
        redirect_uris: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Exact match, except that an unpublished loopback URI matches on any port."
        },
        origins: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "Origins derived from redirect_uris and admitted by CORS. A " <>
              "loopback origin is admitted on any port, not only the port shown here."
        },
        published: %Schema{
          type: :boolean,
          description: "False means development mode with owner-only sign-in."
        },
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :client_id,
        :name,
        :redirect_uris,
        :origins,
        :published,
        :created_at,
        :updated_at
      ]
    })
  end

  defmodule OAuthClientRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OAuthClientRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1},
        redirect_uris: %Schema{
          type: :array,
          items: %Schema{type: :string},
          minItems: 1
        }
      },
      required: [:name, :redirect_uris],
      example: %{
        name: "Notes",
        redirect_uris: ["https://abc123.sprites.app/callback", "http://localhost:5173/callback"]
      }
    })
  end

  defmodule OAuthClientUpdateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OAuthClientUpdateRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1},
        redirect_uris: %Schema{
          type: :array,
          items: %Schema{type: :string},
          minItems: 1
        }
      },
      example: %{name: "Notes for Fountain"}
    })
  end

  list_response(OAuthClientListResponse, of: OAuthClient)

  defmodule Runner do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Runner",
      description:
        "A self-hosted runner: a machine of yours running `fountain runner`, " <>
          "serving sandboxes for the `runner` provider (ADR 0022). `online` is " <>
          "live — whether the daemon holds a connection right now.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string, description: "The `--name` the daemon connected with."},
        hostname: %Schema{type: :string, nullable: true},
        os: %Schema{type: :string, nullable: true},
        arch: %Schema{type: :string, nullable: true},
        version: %Schema{type: :string, nullable: true, description: "The daemon's CLI version."},
        root: %Schema{
          type: :string,
          nullable: true,
          description: "The directory on the machine that holds its sandboxes."
        },
        online: %Schema{type: :boolean},
        connected_at: %Schema{type: :string, format: :"date-time", nullable: true},
        last_seen_at: %Schema{type: :string, format: :"date-time", nullable: true},
        created_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :online, :created_at]
    })
  end

  list_response(RunnerListResponse, of: Runner)

  defmodule ClaimableUser do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ClaimableUser",
      description:
        "A claimable principal (ADR 0044): the anonymous tenant an application " <>
          "opens for a visitor who has no Fountain account yet. `principal_id` is " <>
          "the tenant every resource it builds belongs to, and it never changes — " <>
          "claiming attaches an owner rather than moving anything.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "The grant's id."},
        principal_id: %Schema{
          type: :string,
          format: :uuid,
          description:
            "The tenant id. Baked into every sandbox name the principal creates, " <>
              "and identical before and after a claim."
        },
        application_id: %Schema{
          type: :string,
          description: "The application's own label for itself, as given at creation."
        },
        status: %Schema{type: :string, enum: ~w(unclaimed claimed expired released)},
        expires_at: %Schema{type: :string, format: :"date-time"},
        claimed_at: %Schema{type: :string, format: :"date-time", nullable: true},
        claimed_by_user_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "The account that claimed it. Only shown to that account and to the application."
        },
        budget_exhausted_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the introductory grant first refused a spend, if it has."
        },
        grant_cents: %Schema{
          type: :integer,
          description: "The introductory grant, in cents. Zero when credits are off."
        },
        max_live_sandboxes: %Schema{type: :integer, nullable: true},
        metadata: %Schema{type: :object, description: "Whatever the application stored here."},
        created_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :principal_id, :application_id, :status, :expires_at, :created_at]
    })
  end

  item_response(ClaimableUserResponse, of: ClaimableUser)

  defmodule ClaimableUserCreated do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ClaimableUserCreated",
      description:
        "The grant plus its two secrets. Both are shown once and stored only as " <>
          "hashes. Replaying the create with the same `Idempotency-Key` returns the " <>
          "same principal with a fresh pair, which invalidates this one.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        principal_id: %Schema{type: :string, format: :uuid},
        application_id: %Schema{type: :string},
        status: %Schema{type: :string, enum: ~w(unclaimed claimed expired released)},
        expires_at: %Schema{type: :string, format: :"date-time"},
        grant_cents: %Schema{type: :integer},
        max_live_sandboxes: %Schema{type: :integer, nullable: true},
        metadata: %Schema{type: :object},
        created_at: %Schema{type: :string, format: :"date-time"},
        api_key: %Schema{
          type: :string,
          description:
            "A `principal`-scoped API key for the principal, expiring with it. It " <>
              "reaches agents, environments, vaults, conversations and sandboxes, and " <>
              "nothing that manages an account."
        },
        claim_token: %Schema{
          type: :string,
          description: "The one-time capability that claims this principal."
        }
      },
      required: [:id, :principal_id, :status, :expires_at, :api_key, :claim_token]
    })
  end

  item_response(ClaimableUserCreatedResponse, of: ClaimableUserCreated)

  defmodule ClaimedPrincipal do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ClaimedPrincipal",
      description:
        "The result of a claim. The principal's resources are untouched: the same " <>
          "sandbox, agent, environment, vault and conversations, under the same ids.",
      type: :object,
      properties: %{
        user: %Schema{
          type: :object,
          description: "The account that now owns the principal.",
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            email: %Schema{type: :string, nullable: true}
          }
        },
        principal_id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: ~w(unclaimed claimed expired released)},
        claimed_at: %Schema{type: :string, format: :"date-time"},
        api_key: %Schema{
          type: :string,
          description:
            "A fresh `principal`-scoped key that expires 30 days after issuance. " <>
              "The claim revokes the application credential. Owners can replace the key " <>
              "from API keys in the console, including after expiry."
        }
      },
      required: [:user, :principal_id, :status, :api_key]
    })
  end

  item_response(ClaimedPrincipalResponse, of: ClaimedPrincipal)

  defmodule SecretBinding do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretBinding",
      description:
        "Which host a secret is attached to at the egress broker, and how " <>
          "(ADR 0019). Keyed by the secret's name: it applies wherever an " <>
          "environment or vault holds a secret of that name. A secret with at " <>
          "least one enabled binding reaches the sandbox as a placeholder " <>
          "(`__key__`); one with none reaches it in the clear.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        key: %Schema{type: :string, description: "The secret's name, UPPER_SNAKE_CASE."},
        host: %Schema{
          type: :string,
          description:
            "Host pattern: `api.example.com`, a one-level wildcard `*.example.com`, " <>
              "optionally `:port` and a `/path/*` glob."
        },
        auth_type: %Schema{
          type: :string,
          enum: ["substitute", "bearer", "basic", "api_key", "custom"]
        },
        header: %Schema{
          type: :string,
          nullable: true,
          description: "api_key only: the header the value is sent in. Defaults to Authorization."
        },
        prefix: %Schema{
          type: :string,
          nullable: true,
          description: "api_key only: text placed before the value, such as `Token `."
        },
        username: %Schema{
          type: :string,
          nullable: true,
          description: "basic only: the username; the secret is the password."
        },
        headers: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :string},
          description:
            "custom only: header name to template, `{{ KEY }}` is replaced by the secret."
        },
        enabled: %Schema{type: :boolean},
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :key, :host, :auth_type, :headers, :enabled, :created_at, :updated_at]
    })
  end

  defmodule SecretBindingRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretBindingRequest",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        host: %Schema{type: :string},
        auth_type: %Schema{
          type: :string,
          enum: ["substitute", "bearer", "basic", "api_key", "custom"]
        },
        header: %Schema{type: :string, nullable: true},
        prefix: %Schema{type: :string, nullable: true},
        username: %Schema{type: :string, nullable: true},
        headers: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        enabled: %Schema{type: :boolean}
      },
      required: [:key, :host, :auth_type],
      example: %{key: "STRIPE_SECRET_KEY", host: "api.stripe.com", auth_type: "bearer"}
    })
  end

  defmodule SecretBindingPreset do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretBindingPreset",
      description: "A known service from the broker's catalog, to prefill a binding from.",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        name: %Schema{type: :string},
        host: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        auth_type: %Schema{type: :string},
        suggested_key: %Schema{type: :string, nullable: true},
        header: %Schema{type: :string, nullable: true},
        prefix: %Schema{type: :string, nullable: true},
        headers: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        usable: %Schema{
          type: :boolean,
          description:
            "False for the few presets a binding cannot express on its own (request signing, a username of yours)."
        }
      },
      required: [:id, :name, :host, :auth_type, :usable]
    })
  end

  defmodule EgressEvent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EgressEvent",
      description:
        "One outbound HTTP request the sandbox made through the egress broker " <>
          "(ADR 0019). The row is written when the request ends, so a streamed " <>
          "response is recorded when the stream finishes rather than when it starts.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        at: %Schema{type: :string, format: :"date-time", nullable: true},
        method: %Schema{type: :string},
        host: %Schema{type: :string, description: "Host and port, as the sandbox dialed it."},
        path: %Schema{
          type: :string,
          description: "The URL path. A query string is never recorded: it can hold a credential."
        },
        service: %Schema{
          type: :string,
          nullable: true,
          description:
            "The binding that matched, and so which credential was attached. Null when " <>
              "none was: a passthrough host, or a host allowed under `limited` with no " <>
              "credential bound to it."
        },
        credential_keys: %Schema{type: :array, items: %Schema{type: :string}},
        status: %Schema{
          type: :integer,
          nullable: true,
          description:
            "The upstream status, or the broker's own refusal. Null where no answer arrived."
        },
        latency_ms: %Schema{
          type: :integer,
          nullable: true,
          description:
            "How long the whole request took, request head through response body, " <>
              "not time to first byte."
        },
        error: %Schema{
          type: :string,
          nullable: true,
          description:
            "Why forwarding did not complete, such as `upstream_closed`, " <>
              "`credential_missing` or `request_timeout`. Null on a request that did."
        }
      },
      required: [:id, :method, :host, :path, :credential_keys]
    })
  end

  defmodule EgressListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EgressListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: EgressEvent},
        next: %Schema{
          type: :integer,
          nullable: true,
          description: "Pass as `before` for the next page; null at the end."
        },
        brokered: %Schema{
          type: :boolean,
          description: "False when the conversation was not brokered; `data` is then empty."
        }
      },
      required: [:data, :brokered]
    })
  end

  list_response(SecretBindingListResponse, of: SecretBinding)
  list_response(SecretBindingPresetListResponse, of: SecretBindingPreset)

  defmodule ApiKeyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKeyRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, description: "What this key is for."}
      },
      required: [:name]
    })
  end

  defmodule ApiKeyCreatedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKeyCreatedResponse",
      description: "The one and only response that carries key material.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        key: %Schema{type: :string, description: "Plaintext key. Not recoverable afterwards."},
        prefix: %Schema{type: :string},
        created_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :key, :prefix]
    })
  end

  defmodule RegisterRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RegisterRequest",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email},
        password: %Schema{type: :string, format: :password}
      },
      required: [:email, :password]
    })
  end

  defmodule RegisterResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RegisterResponse",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        message: %Schema{type: :string}
      },
      required: [:user_id, :message]
    })
  end

  defmodule EmailRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EmailRequest",
      type: :object,
      properties: %{email: %Schema{type: :string, format: :email}},
      required: [:email]
    })
  end

  defmodule TokenRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenRequest",
      description: "A token lifted out of an emailed link.",
      type: :object,
      properties: %{token: %Schema{type: :string}},
      required: [:token]
    })
  end

  defmodule VerifyEmailResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VerifyEmailResponse",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        email_verified: %Schema{type: :boolean},
        message: %Schema{type: :string}
      },
      required: [:user_id, :email_verified, :message]
    })
  end

  defmodule PasswordResetRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasswordResetRequest",
      type: :object,
      properties: %{
        token: %Schema{type: :string, description: "From the reset email."},
        password: %Schema{type: :string, format: :password}
      },
      required: [:token, :password]
    })
  end

  defmodule PasswordChangeRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasswordChangeRequest",
      type: :object,
      properties: %{
        current_password: %Schema{type: :string, format: :password},
        new_password: %Schema{type: :string, format: :password}
      },
      required: [:current_password, :new_password]
    })
  end

  defmodule PasswordChangeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasswordChangeResponse",
      type: :object,
      properties: %{
        message: %Schema{type: :string},
        sessions_invalidated: %Schema{type: :boolean},
        api_keys_revoked: %Schema{
          type: :boolean,
          description:
            "Always false. API keys are separate credentials with their own " <>
              "expiries; revoke them yourself at `DELETE /api/auth/api-keys/{id}`."
        }
      },
      required: [:message, :sessions_invalidated, :api_keys_revoked]
    })
  end

  defmodule EmailChangeRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EmailChangeRequest",
      type: :object,
      properties: %{
        new_email: %Schema{type: :string, format: :email},
        current_password: %Schema{type: :string, format: :password}
      },
      required: [:new_email, :current_password]
    })
  end

  defmodule EmailChangedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EmailChangedResponse",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email, description: "The new address."},
        message: %Schema{type: :string}
      },
      required: [:email, :message]
    })
  end

  defmodule Connection do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Connection",
      description:
        "A provider account the tenant signed in to once, whose credential " <>
          "Fountain holds (#1178). Agents get the capability, never the token: " <>
          "an agent's `mcp_servers` names the connection " <>
          ~s|(`{"gmail": {"connection": "<id>"}}`) and Fountain serves the Gmail | <>
          "tools; and the access token is brokered under `env_key` for an MCP " <>
          "server the tenant runs. Only on a deployment that runs the egress broker.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        provider: %Schema{
          type: :string,
          description: "The provider's slug: `google`, or a tenant provider's."
        },
        provider_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "The tenant provider (#1186); null for the platform provider."
        },
        account_email: %Schema{
          type: :string,
          description: "The connected account: an address, or the label the provider gave."
        },
        scopes: %Schema{type: :array, items: %Schema{type: :string}},
        env_key: %Schema{
          type: :string,
          description:
            "The env var name the access token is brokered under (`GOOGLE_ACCESS_TOKEN`)."
        },
        status: %Schema{
          type: :string,
          enum: ["active", "revoked", "expired"],
          description:
            "`revoked` once the tenant cut it or the provider refused the refresh token; " <>
              "`expired` when the access token lapsed and the provider issued no refresh token. " <>
              "The row stays so the console can say why the tools stopped. Reconnect to replace it."
        },
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the cached access token expires. Refreshed on use."
        },
        revoked_at: %Schema{type: :string, format: :"date-time", nullable: true},
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :provider, :account_email, :scopes, :env_key, :status]
    })
  end

  list_response(ConnectionListResponse, of: Connection)

  defmodule ConnectionProvider do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConnectionProvider",
      description:
        "Where a connection's tokens come from (#1186, #1299): a platform " <>
          "provider (`platform: true`, id `google`, `microsoft` or `slack` — " <>
          "Fountain's own OAuth client), a tenant's own OAuth app at a " <>
          "service (`kind: oauth2`), or a remote MCP server whose authorization " <>
          "Fountain discovered (`kind: mcp`). The client secret is never returned.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "A uuid, or a platform slug."},
        slug: %Schema{type: :string},
        name: %Schema{type: :string},
        kind: %Schema{type: :string, enum: ["oauth2", "mcp"]},
        platform: %Schema{
          type: :boolean,
          description: "True for a platform provider, which has no row."
        },
        configured: %Schema{
          type: :boolean,
          description: "True when the provider has a client Fountain can start a flow with."
        },
        authorize_url: %Schema{type: :string, nullable: true},
        token_url: %Schema{type: :string, nullable: true},
        revoke_url: %Schema{type: :string, nullable: true},
        userinfo_url: %Schema{type: :string, nullable: true},
        account_label_path: %Schema{
          type: :string,
          nullable: true,
          description: "A dotted path into the userinfo body that names the account."
        },
        scopes: %Schema{type: :array, items: %Schema{type: :string}},
        client_id: %Schema{type: :string, nullable: true},
        has_client_secret: %Schema{type: :boolean},
        token_endpoint_auth: %Schema{
          type: :string,
          enum: ["client_secret_post", "client_secret_basic", "none"]
        },
        pkce: %Schema{type: :boolean},
        env_key: %Schema{
          type: :string,
          description: "The env var a connection's access token is brokered under."
        },
        token_hosts: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "The hosts the brokered token is attached to as a bearer."
        },
        mcp_url: %Schema{type: :string, nullable: true},
        issuer: %Schema{
          type: :string,
          nullable: true,
          description: "The authorization server discovery found (`mcp`)."
        },
        client_source: %Schema{
          type: :string,
          nullable: true,
          enum: ["dcr", "manual", nil],
          description: "`dcr` when the client came from RFC 7591 registration."
        },
        registration_endpoint: %Schema{type: :string, nullable: true},
        redirect_uri: %Schema{
          type: :string,
          description: "The callback to register at the service."
        },
        connect_url: %Schema{
          type: :string,
          description:
            "Where to send the account owner, in a browser signed in to the console, " <>
              "to connect an account."
        },
        created_at: %Schema{type: :string, format: :"date-time", nullable: true},
        updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [
        :id,
        :slug,
        :name,
        :kind,
        :platform,
        :configured,
        :scopes,
        :env_key,
        :token_hosts,
        :redirect_uri,
        :connect_url
      ]
    })
  end

  list_response(ConnectionProviderListResponse, of: ConnectionProvider)

  defmodule ConnectionProviderRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConnectionProviderRequest",
      description:
        "`kind: oauth2` needs `name`, `authorize_url`, `token_url`, `client_id` and " <>
          "`client_secret` (unless `token_endpoint_auth` is `none`). `kind: mcp` " <>
          "needs `mcp_url`; the rest comes from discovery. `slug` defaults from the " <>
          "name or the server host, `env_key` from the slug (`GITHUB_ACCESS_TOKEN`).",
      type: :object,
      properties: %{
        kind: %Schema{type: :string, enum: ["oauth2", "mcp"]},
        slug: %Schema{type: :string},
        name: %Schema{type: :string},
        authorize_url: %Schema{type: :string},
        token_url: %Schema{type: :string},
        revoke_url: %Schema{type: :string, nullable: true},
        userinfo_url: %Schema{type: :string, nullable: true},
        account_label_path: %Schema{type: :string, nullable: true},
        scopes: %Schema{type: :array, items: %Schema{type: :string}},
        client_id: %Schema{type: :string},
        client_secret: %Schema{type: :string, description: "Write-only."},
        token_endpoint_auth: %Schema{
          type: :string,
          enum: ["client_secret_post", "client_secret_basic", "none"]
        },
        pkce: %Schema{type: :boolean},
        env_key: %Schema{type: :string},
        token_hosts: %Schema{type: :array, items: %Schema{type: :string}},
        mcp_url: %Schema{type: :string}
      },
      example: %{
        kind: "oauth2",
        slug: "github",
        name: "GitHub",
        authorize_url: "https://github.com/login/oauth/authorize",
        token_url: "https://github.com/login/oauth/access_token",
        userinfo_url: "https://api.github.com/user",
        account_label_path: "login",
        scopes: ["repo", "read:user"],
        client_id: "Iv1.abc",
        client_secret: "…",
        token_hosts: ["api.github.com"]
      }
    })
  end
end
