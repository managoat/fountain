# About vaults

This page explains what a Fountain Vault is, why it exists, and why it is not
the thing its name suggests. For each field, read the
[API reference](../api.md). For the commands, read the
[CLI reference](../cli.md).

## If you have used HashiCorp Vault, read this first

The names collide and the meanings are close to opposite. Get this backwards
and you build exactly the wrong model of how a credential reaches a sandbox.
Thirty seconds here saves that.

| HashiCorp Vault | Fountain Vault |
|---|---|
| One central server that you deploy, cluster and unseal. | A small record in Fountain's database. Make as many as you want. |
| The authoritative store. What Vault holds is true. | A patch layer. The Environment is the baseline, and the Vault overrides it. |
| Issues dynamic, leased, revocable credentials. | Holds static values that you wrote. No leases, no rotation, no revocation. |
| Sealed until an operator unseals it. | No state at all. There is nothing to unseal. |
| Path mounts, and a policy for each path. | One flat bag of keys and values, scoped to your tenant. |
| Precedence is not a concept. | Precedence is the whole point. |

One thing does carry over. Both products encrypt with an envelope.

HashiCorp goes unseal key, then root key, then keyring, then data.
Fountain goes `MASTER_SECRETS_KEY`, then one data encryption key for each
tenant, then the value. If you understood theirs, you already understand
[ours](../architecture.md).

## What a vault is

A Vault is a named bag of environment variable overrides. It layers over an
Environment for one run.

It floats free. It belongs to no Agent and to no Environment. You can attach
it to any conversation that the Agent's `allowed_vault_ids` permits. You can
also attach one Vault to conversations of different Agents at the same time.

```yaml
apiVersion: fountain.dev/v1
kind: Vault
metadata:
  name: staging-creds
spec:
  secrets:
    DATABASE_URL: postgres://staging-host/mydb
```

`secrets` must be a map of `KEY: value`. The server keeps only the map form
and drops any other shape without an error.

## Why it exists

Without vaults, one credential change means an edit to the Environment. The
whole team shares that Environment. Three results follow, and teams meet all
three.

To run one Agent against staging and production, you would need two
Environments. The two would be the same except for one URL, and they would
drift apart.

To give a contractor's agent a scoped token, you would widen the shared
Environment or clone it.

To rotate one key, you would touch each agent on that Environment. Some of
them do not use the key at all.

A Vault turns each of those into a one-line attachment on a single run. The
shared thing stays as it is.

## The merge rule

A Conversation starts. Fountain then builds the environment variable set in
one direction.

```
environment secrets  --merge-->  vault secrets  -->  the sandbox
                                       ^
                               wins on collision
```

The Vault wins. The Environment sets `DATABASE_URL`, the attached Vault sets
`DATABASE_URL` too, and the process sees the Vault's value.

The merge happens once, at spawn. An edit to a Vault does not reach a sandbox
that already runs. A brokered secret is the exception. Fountain reads the
Vault again before each turn and gives the broker the new value, so a rotated
token works on the next turn. [Secrets](secrets.md) has the detail.

A key that only the Environment sets survives untouched. A Vault is a patch,
and not a replacement.

## What a vault is not

**Not rotation.** A value that you place in a Vault stays there until you
change it. Fountain does not expire it, does not renew it, and does not tell
an agent that it went stale.

**Not revocation.** Remove a Vault from an Agent's `allowed_vault_ids` and no
later conversation can attach it. A sandbox that already runs keeps the value
you gave it. By then the value sits in a process environment on a machine.

**Not a read audit.** Fountain audits the mutation when you write a secret, by
key and by size. It does not record that an agent read one, because that read
happens in the sandbox.

**Not returnable.** Values are write-only. A list of a Vault returns keys and
timestamps. No endpoint gives you a value back, not even to the owner.

## Copy a vault

Values are write-only, so a client cannot read one vault and write its
secrets into another. Fountain copies them on the server instead:

```bash
curl --fail-with-body -X POST \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"staging-creds-track-42"}' \
  "$FOUNTAIN_URL/api/vaults/$SOURCE_VAULT_ID/copy"
```

The request takes the same body as creating a vault. `name` is required.
`description` and `metadata` default to the source's. The response is the new
vault, exactly as a create returns it, with status `201`. It never contains a
value.

Each secret is decrypted and encrypted again into the new vault, with its
expiry date. The copy is a separate vault from then on. A later write to either
vault does not reach the other.

The copy is all or nothing. A name that is already taken returns `422` and
creates nothing. So does a source secret that can no longer be written, for
example one that no longer decrypts. That response names the key, so you can
rewrite it in the source and copy again. You can copy only your own vaults.
Another account's vault returns `404`, the same as a vault that does not exist.

The audit trail records `vault.created` for the copy, with the source in
`copied_from`, and one `vault.secret.write` for each key copied. It records keys
and never values.

Use a copy when every workstream needs the same shared secrets plus one or two
of its own, such as a clone token. Copy the shared vault, then write the extra
secrets into the copy.

## When to use something else

Use an [Environment](environment.md) for what the whole team shares and what
changes rarely.

Use `env_vars` on an Environment for a value that is not sensitive. A Vault
that holds one non-secret is a Vault that somebody later assumes is secret.

Use [inference credentials](../integrations/index.md) for model API keys.
Those belong to one user, and they never belong in a Vault. You enter them in
the console or over the
[inference credentials API](../api.md#inference-credentials).

## Secret expiry

A secret can carry an expiry date. The date is optional metadata. Fountain
does not block an expired secret, because an absent variable fails worse than
a stale one.

Fountain sends one email before the date arrives. The notice window is
seven days.

Set the date when you write the secret, in the console or over the API.
When you replace a value, a blank date in the add-secret form keeps the
stored date.

To change only the expiry, edit the date beside the secret
and select **Save expiry**. A blank date removes the expiry. Console dates use
the end of the selected day in UTC.

The API accepts `PATCH /api/vaults/:vault_id/secrets/:key` with
`{"expires_at":"2027-01-15T00:00:00Z"}`. Send `{"expires_at":null}` to clear the
date; `{}` keeps it. This endpoint accepts only expiry metadata. Values stay
write-only, and expiry remains advisory.

With the TypeScript SDK, use
`fountain.vaults.secrets.update("staging-creds", "TOKEN", {expires_at: null})`.

## What we chose not to do

We looked at precedence for each key, so that one Environment key could refuse
an override from a Vault. We rejected it.

A merge rule that always holds is worth more than a merge rule that says more.
The reader must hold the rule in their head at the moment they debug a wrong
credential, and that moment is usually a bad one.

We also looked at the other order, with the Vault as the baseline and the
Environment as the override. That would have matched the HashiCorp prior. We
rejected it, because the thing that changes rarely must be the base.

## Where to go next

- [About environments](environment.md), the other half of the merge.
- [About agents](agent.md), which decides which vaults you can attach.
- [Architecture](../architecture.md), for the full encryption chain.
- [CLI reference](../cli.md), for `fountain vault`.
