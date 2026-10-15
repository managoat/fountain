# Run Codex on a ChatGPT subscription

The `codex` runtime can run on a ChatGPT plan instead of an OpenAI API key.
You link the plan once. Codex conversations then run on it, and the usage
counts against the plan's Codex limits rather than an API bill.

Each account can link one subscription. The deployment has none of its
own.

## Which credential a codex conversation uses

For a codex agent on an `openai/` model, Managoat takes the first of these
that exists:

1. The account's own ChatGPT subscription.
2. The account's own OpenAI API key: the one on **Inference credentials**,
   or `OPENAI_API_KEY` in the conversation's environment or vault. This is
   the order described in [Where a secret comes from](../concepts/secrets.md).

With neither, the conversation has no credential to run codex on. A
conversation never moves to another credential: start a new one to use a
credential you added since.

A subscription is only used on a deployment that runs the egress broker
(`BROKER_LISTEN_PORT`). The broker holds the access token and adds it to
Codex's requests to `chatgpt.com`. The sandbox gets a placeholder and never
the token. Without the broker the token would have to go into the sandbox,
so Managoat skips the subscription and uses an API key.

## Link your subscription

Open **Inference credentials** (`/account/inference-credentials`). Use one
of these two ways:

- **Link with a code.** Managoat shows a code and a link to
  `auth.openai.com`. Open the link, sign in to ChatGPT and enter the code. The
  page waits for the approval and says when the subscription is linked. The
  code is good for fifteen minutes. Leave the page open until it finishes.
- **Paste an `auth.json`.** Run `codex login` on your own machine and choose
  ChatGPT. Then paste the contents of `~/.codex/auth.json`. The file and
  Managoat then share one refresh token. Whichever side refreshes it second
  can be signed out, so run `codex login` on that machine again afterwards.
  Use the code when you can.

Linking again replaces the subscription. If you link the same ChatGPT
account, running conversations carry on. If you link a different account,
start new conversations: a conversation stays on the account it started on.

## How Managoat keeps it signed in

An access token lasts about ten days. Once a day, at 04:29 UTC, Managoat
refreshes every subscription that nobody has refreshed for six days. That is
the only routine call Managoat makes to `auth.openai.com`.

Before each turn, Managoat reads the stored access token and puts it in the
broker. This is a database read, not a call to OpenAI. There is one
exception: when the stored token has already expired, or expires within ten
minutes, Managoat refreshes it before the turn.

If OpenAI refuses the refresh for good, the card shows **Reconnect** and the
reason. Link the subscription again.

## When something goes wrong

- **`409 chatgpt_reconnect_required`.** The subscription this conversation
  runs on was disconnected, refused by OpenAI, or linked to a different
  account. Link it again and send the prompt again.
- **The plan's usage limit.** The turn fails with the error OpenAI returns.
  Managoat does not switch to another credential.
  Wait for the reset, or link a different subscription and start a new
  conversation.

## Disconnect

Select **Disconnect** on the card. Managoat deletes its copy of the tokens,
and conversations on the subscription stop at their next prompt. Managoat
cannot sign the device out at OpenAI. To end the sign-in there too, remove it
in the ChatGPT account's security settings.

Deleting your account deletes your subscription.
