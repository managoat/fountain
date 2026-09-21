# Run Codex on a ChatGPT subscription

This guide shows you how to link a ChatGPT subscription to your account, point
a credential set at it, and run the `codex` runtime on it instead of an OpenAI
API key. You do it on one console page, **Account, then Inference
credentials** (`/account/inference-credentials`). The same operations are in
the [API](../api.md#chatgpt-subscriptions).

!!! note "ChatGPT subscriptions"

    Linking a ChatGPT subscription is in development and off for every
    account. The **ChatGPT subscriptions** card is absent from the page
    unless the `chatgpt_subscriptions` flag is on for your account and the
    deployment runs the credential broker, or your account already holds a
    subscription. See [feature status](../reference/feature-status.md) for
    what is not built yet. Do not rely on this feature for work that must
    not stop.

## What a linked subscription is

A linked subscription is a ChatGPT sign-in that Fountain holds for you. It
has a name that you choose. Fountain stores its tokens encrypted with your
tenant key and renews them. A sandbox never receives the token: codex in the
sandbox holds a placeholder, and the credential broker puts the real token
on the request to OpenAI.

An account can link up to five subscriptions, or the number that the operator
set in [`CHATGPT_GRANT_CEILING`](../configuration.md). The card shows the
count, for example `2 of 5`. A disconnected subscription keeps its place until
you remove it.

## 1. Link a subscription

1. Open **Account, then Inference credentials**.
2. In the **ChatGPT subscriptions** card, type a name, for example
   `Work ChatGPT`, and click **Connect a subscription**.
3. The card shows a code and a link to `https://auth.openai.com/codex/device`.
   Open the link in a browser where you are signed in to the ChatGPT account
   that you want to link. Enter the code and approve.
4. Wait. The page updates by itself when ChatGPT reports the approval, and
   the subscription shows **Connected** with its email and plan.

The code is good for 15 minutes. You can reload the page or close it: the
sign-in is stored on the server, and the page shows the same code when you
come back. **Cancel** ends a sign-in. An account can have three sign-ins open
at a time, and can start ten in an hour. The API and the console share both
limits. When you reach the second one, the card says how long to wait.

If ChatGPT's sign-in service stops answering, the sign-in stays open and the
card says so. Fountain asks again less often, so an approval can take up to a
minute to show.

Device-code sign-in must be on in the security settings of the ChatGPT
account. If ChatGPT refuses the code, the card says so.

### Approve only a code that you started

The code links **the ChatGPT account that approves it** to **the Fountain
account that started it**. If another person sends you a code and you approve
it, their Fountain account gets the use of your ChatGPT plan. Approve a code
only when you started the sign-in yourself, on this page, a moment ago.
Fountain never sends you a code by email or chat.

Fountain shows the link only when it is an `https` address on
`auth.openai.com`. Check the address bar before you type the code.

## 2. Point a credential set at it

A subscription does nothing until a
[credential set](../concepts/secrets.md#credential-sets) names it.

1. On the same page, select the set. An account with one set has nothing to
   select.
2. In the **ChatGPT subscription** row, choose the subscription and click
   **Save**.

Agents on that set now run `codex` on the subscription. Each other runtime
still uses the keys in the set: OpenCode on an `openai/` model needs an OpenAI
API key, and the subscription is not one.

**To change what a set names ends the codex conversations that run on that
set.** A conversation is bound to the source it started on. Its next turn is
refused with `inference_source_changed`. Start a new conversation. The
**Save** button asks you to confirm this.

Choose **None** to stop naming a subscription.

## What happens when the subscription cannot serve

A named subscription is used or the run fails. Fountain does not switch to
another subscription, to the set's OpenAI key or to platform inference.

| State on the card | What a codex run on a set that names it gets | What to do |
|---|---|---|
| **Connected** | It runs. | Nothing. |
| **Reconnect required** | `409 chatgpt_grant_unusable` with the subscription's name. | Click **Reconnect**, then start a new conversation. |
| **Disconnected** | The same refusal. | Click **Reconnect**, or point the set at another subscription. |
| **Cannot serve here** | The same refusal. The deployment does not run the credential broker. | Ask the operator. **Reconnect** does not help. |
| **Usage spent** | The same refusal, with `reason` `exhausted` and the reset time in `until`. | Wait for the reset, or point the set at another subscription. |

**Fountain detects a spent plan after a turn fails on it.** The first turn
that reaches the limit fails with the message from codex. Fountain then asks
OpenAI about that subscription. When OpenAI confirms the limit, the card
changes to **Usage spent** and shows the reset time. An open page changes
without a reload. Each launch and each turn on the subscription is then
refused until the reset time. Fountain does not switch to another
subscription, to a key or to platform inference. When the reset time passes,
the card shows **Connected** again and the same conversations can continue.

Fountain asks OpenAI at most one time in 5 minutes for each subscription. If
that request fails, the subscription stays **Connected** and its turns keep
failing with the message from codex. The next request can be up to 5 minutes
later. Fountain does not check usage before a turn fails, and it sends no
email and no webhook about a spent plan.

An account that is suspended cannot run on a subscription, whatever state the
card shows. The card and the **ChatGPT subscription** row say so.

The `/start` page and the agent form show the same sentence before you launch
anything.

## Reconnect, rename, disconnect, remove

- **Reconnect** starts a second sign-in for the same subscription. The
  subscription keeps its name, and each set that names it keeps naming it. A
  connected subscription keeps working on its old sign-in until you approve
  the new one. After the approval, conversations that ran on the old sign-in
  end. Start new ones.
- **Rename** changes the label and nothing else.
- **Disconnect** makes Fountain forget the sign-in at once. No later request
  from a sandbox can use it, and conversations that ran on it stop. A sign-in
  that is open for it is discarded, approved or not. Sets that
  named it still name it, and their codex runs are refused by name until you
  reconnect it. Fountain does not revoke the token at OpenAI. To do that, sign
  the device out in your ChatGPT account.
- **Remove** deletes a disconnected subscription and frees its place. A
  sign-in that is open for it is discarded. If
  credential sets still name it, the card lists them. Point each at another
  subscription or at **None** first.

Two sign-in results need an action from you:

- **"Was discarded".** The subscription changed while the sign-in was
  open, because a newer sign-in finished first or you disconnected it.
  Fountain discarded the sign-in, approved or not, and left the subscription
  as it was. Reconnect again if it still needs a sign-in.
- **"Already linked here as …".** The ChatGPT account that approved the code
  is one that another of your subscriptions holds. One ChatGPT account is
  linked once. Reconnect the subscription that the message names. Or sign in
  to ChatGPT with the other account in your browser, and start again.

The card shows how a sign-in ended for 30 minutes, also after a page reload
and on a page that was not open when it ended. It shows the three most recent
results. When you start another sign-in, the page stops showing them until you
reload it. The [API](../api.md#chatgpt-subscriptions) reads an ended sign-in
by its ID for a week.

## An idle subscription stays signed in

OpenAI is assumed to end a sign-in that nobody renews for about 8 days.
Fountain has not measured that time. Fountain renews
each subscription before each turn that needs it. It also renews a
subscription that nobody used: each day at 04:37 UTC, Fountain looks for
subscriptions that were last renewed 6 days ago or more, and renews each one.
**Last renewed** on the card shows the time of the most recent renewal, from
either cause. You do nothing, and no conversation has to run.

Each subscription is renewed by itself. If OpenAI refuses the sign-in of one
subscription, because it was used in another place or revoked, that
subscription changes to **Reconnect required** and your other subscriptions
are renewed as usual. Click **Reconnect** for that one.

Fountain does not renew a disconnected subscription, a subscription in
**Reconnect required**, or the subscription of an account that is suspended.
The 6 days are provisional, because the 8 days are an assumption.

## Export and account deletion

The [account export](../api.md#data-export-and-deletion) lists your subscriptions and
your sign-ins of the last week. For a subscription, the export has the name,
the state, the plan, the email that OpenAI reported, the times, and the names
of the credential sets that name it. For a sign-in, the export has what it was
for and how it ended.

The export never has a token, the code that you typed, OpenAI's ID for your
ChatGPT account, or an encrypted copy of one of them.

When you delete your account, Fountain deletes your subscriptions, your
sign-ins and its copy of each token. **Fountain cannot revoke a sign-in at
OpenAI.** The sign-in stays valid at OpenAI until it expires or you end it. To
end it, sign the device out in your ChatGPT account. The email that confirms
the deletion says the same.

## When linking is off

The flag holds one door, a sign-in for a **new** subscription. With the flag
off, the card stays for an account that holds a subscription. **Connect** is
absent, and a set is not offered a subscription that it does not name already.
You can still rename, reconnect, disconnect and remove each subscription, and
a set can stop naming one. On a deployment with no credential broker, a
subscription cannot serve a run or be reconnected, and the card says so.

## Setup scripts and `CODEX_HOME`

Codex keeps each subscription's sign-in in a home of its own, and Fountain
sets `CODEX_HOME` to that directory for the conversation. Package installs,
repository clones and the environment's `setup_script` run with the same
variable, before Fountain prepares the directory. Do not run `codex` in a
setup script for such an agent. Codex would create the directory itself, and
the conversation would then run on the `config.toml` that your script's run
made, without the MCP servers that Fountain writes for the agent. Do not
write to `$CODEX_HOME` in a setup script for the same reason. Put Codex
settings in the `CODEX_CONFIG` variable of the environment, which Fountain
applies over the file.

## Related

- [Credential sets](../concepts/secrets.md#credential-sets)
- [Run Codex as an API](../catalog/runtimes/codex.md)
- [The ChatGPT subscriptions API](../api.md#chatgpt-subscriptions)
- [Feature status](../reference/feature-status.md)
