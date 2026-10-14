# Run Codex on a ChatGPT subscription

The `codex` runtime can run on a ChatGPT plan instead of an OpenAI API key.
You link the plan once. Codex conversations then run on it, and the usage
counts against the plan's Codex limits rather than an API bill.

Each account can link one subscription. An admin can also link one for the
whole deployment. An account with neither a subscription nor an OpenAI API
key of its own runs on that one.

## Which credential a codex conversation uses

For a codex agent on an `openai/` model, Fountain takes the first of these
that exists. The account's own credentials come before the deployment's:

1. The account's own ChatGPT subscription.
2. The account's own OpenAI API key: the one on **Inference credentials**,
   or `OPENAI_API_KEY` in the conversation's environment or vault. This is
   the order described in [Where a secret comes from](../concepts/secrets.md).
3. The deployment's ChatGPT subscription.
4. `PLATFORM_OPENAI_API_KEY`.

To run on the deployment's subscription when you hold an OpenAI key, remove
your key. A conversation never moves to another credential. When you add a
key, a conversation already on the deployment's subscription either stays
on it, or its next prompt gets `409 inference_source_changed`. It stays when
the key went into **Inference credentials** and the account had no saved
credentials when that conversation started. Start a new conversation to
use your key.

A subscription is only used on a deployment that runs the egress broker
(`BROKER_LISTEN_PORT`). The broker holds the access token and adds it to
Codex's requests to `chatgpt.com`. The sandbox gets a placeholder and never
the token. Without the broker the token would have to go into the sandbox,
so Fountain skips the subscription and uses an API key.

## Link your subscription

Open **Inference credentials** (`/account/inference-credentials`). Use one
of these two ways:

- **Link with a code.** Fountain shows a code and a link to
  `auth.openai.com`. Open the link, sign in to ChatGPT and enter the code. The
  page waits for the approval and says when the subscription is linked. The
  code is good for fifteen minutes. Leave the page open until it finishes.
- **Paste an `auth.json`.** Run `codex login` on your own machine and choose
  ChatGPT. Then paste the contents of `~/.codex/auth.json`. The file and
  Fountain then share one refresh token. Whichever side refreshes it second
  can be signed out, so run `codex login` on that machine again afterwards.
  Use the code when you can.

Linking again replaces the subscription. If you link the same ChatGPT
account, running conversations carry on. If you link a different account,
start new conversations: a conversation stays on the account it started on.

## Link the deployment's subscription

An admin does the same from **Admin → Inference** (`/admin/inference`). The
card there is the deployment's subscription. Every account that has neither
linked its own subscription nor saved its own OpenAI API key runs codex on
it, ahead of `PLATFORM_OPENAI_API_KEY`. Nothing
limits what accounts spend from it except the plan's own limits.

Link it only on a deployment whose accounts you trust. The broker keeps the
token out of the sandboxes, but it adds the token to every request a sandbox
sends to `chatgpt.com`. A `chatgpt.com` response that echoed the token back
would show it to that account's agent.

## How Fountain keeps it signed in

An access token lasts about ten days. Once a day, at 04:29 UTC, Fountain
refreshes every subscription that nobody has refreshed for six days. That is
the only routine call Fountain makes to `auth.openai.com`.

Before each turn, Fountain reads the stored access token and puts it in the
broker. This is a database read, not a call to OpenAI. There is one
exception: when the stored token has already expired, or expires within ten
minutes, Fountain refreshes it before the turn.

If OpenAI refuses the refresh for good, the card shows **Reconnect** and the
reason. Link the subscription again.

## When something goes wrong

- **`409 chatgpt_reconnect_required`.** The subscription this conversation
  runs on was disconnected, refused by OpenAI, or linked to a different
  account. Link it again and send the prompt again.
- **The plan's usage limit.** The turn fails with the error OpenAI returns.
  Fountain does not switch to another credential.
  Wait for the reset, or link a different subscription and start a new
  conversation.
- **A persistent sandbox and a new source.** All codex conversations on one
  persistent sandbox share one Codex sign-in, so they must use the same
  source. A conversation that resolves to a different one is refused with
  `409 codex_inference_conflict`. Start it with `sandbox_mode: "ephemeral"`,
  or reset the sandbox.

## Disconnect

Select **Disconnect** on the card. Fountain deletes its copy of the tokens,
and conversations on the subscription stop at their next prompt. Fountain
cannot sign the device out at OpenAI. To end the sign-in there too, remove it
in the ChatGPT account's security settings.

Deleting your account deletes your subscription.
