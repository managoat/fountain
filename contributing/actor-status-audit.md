# Conversation actor status audit (#2393)

Audited `main` at `361c5c6bd` for
[#2393](https://github.com/managoat/fountain/issues/2393), split from
[#2021 item 3](https://github.com/managoat/fountain/issues/2021). This inventory
covers actor-originated conversation `running` and `failed` writes, including
the extracted modules and the actor's provision watchdog. Turn and sandbox
status writes are different rows; release remains #2392's separate contract.

| Write and caller | Ownership evidence and disposition |
| --- | --- |
| `Reattachment.attempt_session_attach/4`, from `ConversationServer` reattachment | Unsafe. The actor reads a running turn, waits for the provider's session list, and then refreshes the parent. A wake can rebind it while listing is outstanding. The refreshed parent belongs to the replacement, but the old machine's successful attach wrote it `running`. `ActorStatus.running/1` now checks the actor's original sandbox in the status UPDATE. A refusal stops the old command and creates no peer or `session_attached` stage. |
| `ConversationServer.provision_with_rows/3`, credential failure after `SpriteEnv.resolve_inference/4` | Unsafe. Inference resolution's configuration lock ends before machine retirement and the parent failure write. A delayed `Machine.fail_provision/2` can return after a wake commits the replacement. The machine's lease governs its own row, not the conversation binding. The parent now uses `ActorStatus.fail/2` after retirement. |
| `ConversationServer.dispatch_provision/7`, missing MCP variables | Unsafe for the same concrete retirement interval. Synchronous substitution does not protect the later parent write while the machine owner is being awaited. Uses the same guarded failure report. |
| `FreshProvision.announce_failed_provision/3`, pipeline error or failed create/preflight | Unsafe. A pipeline/provider failure can arrive after rebinding. The machine protocol's lease and compare-and-set protect the old machine; the parent is not locked across the pipeline. The known foreign-owner result clauses remain quiet, and other failures now report through the guarded parent write. |
| `FreshProvision.do_run/6` rescue, exception from the provision pipeline | Unsafe. An exception after the rebind bypasses the ordinary foreign-owner result clauses. The rescue now retires the old machine and uses the same guarded failure report. |
| `ProvisionWatchdog.expire/1`, successful retire or exhausted error retries | Unsafe. This separate process retains the original sandbox ID while awaiting retirement. Both failure arms previously refreshed the parent by conversation ID alone, so either could fail a replacement. They now carry the watchdog's original binding through `ActorStatus.fail/2`. The claimed-elsewhere stand-down and bounded stop policy are unchanged. |
| `Connection.open_autonomous_turn/5`, after `Machine.admit_turn/3` | Unsafe redundant write. Admission already commits the running turn and parent status atomically. After it returns, a wake can rebind the conversation before the second unguarded `running` write. Removed that second write; admission still sends the sidebar notification. The admitted turn's started event still describes its committed admission. |
| `Conversations._unsafe_create_turn_on_sandbox/4`, through `Machine.admit_turn/3` for user/autonomous turns | Safe. Under the machine advisory lock, the transaction locks the parent `FOR UPDATE`, checks attachment, locks the sandbox `FOR SHARE`, and inserts the turn plus parent `running` write before committing. A rebind cannot commit between the binding verdict and status write. Covered by the existing admission, shared-sandbox and turn-parent tests. |
| `Launch.fail_pending_binding/3`, delayed initial server-start error | Safe. `Machine.fail_provision/2` invokes this callback inside its finalize transaction. The callback locks the parent `FOR UPDATE`, checks the original tenant/sandbox/pending binding and machine identity/status, then writes `failed` under that same lock. `initial_start_failure_test.exs` already covers a delayed error preserving a replacement. |

The new `ActorStatus` helper uses one conditional SQL UPDATE with the actor's
conversation ID and original sandbox ID. It also refuses terminal parents.
There is no ownership read followed by a separate unguarded write. Sidebar
notifications and terminal provision stages happen only after an accepted
write. Machine retirement, turn recovery and non-status configuration writes
are outside this helper's contract.

`actor_status_binding_test.exs` drives the real server through provider and
credential seams, rebinding at the exact delayed-return boundaries above.
Every failure path has a matching current-actor case that must still persist
`failed` and publish its failure stage. Reattachment also checks the current
actor's peer and success event, and the stale actor's command cleanup and
absence of peer/event. Watchdog tests explicitly deliver all retry messages;
none relies on sleeps to win a race. The autonomous test verifies admission
first committed `running`, then proves its delayed caller cannot overwrite
the replacement's `idle` status.

This closes only the status-write audit. It does not establish resolution of
#2021's co-tenant rebinding or abandoned-turn recovery items, nor add a new
reconciler. A binding guard also does not distinguish two incarnations that
still name the same sandbox; that is a separate ownership contract.
