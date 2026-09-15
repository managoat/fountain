# Run your first agent

One request gets a reply from an agent in its own sandbox. You need an
account and nothing else. No repository, no GitHub token, and no install.

## 1. Your key and your agent

Your start page holds an API key and the id of your agent. The page adds both
to the request below, and it shows a key once. Copy the key there.

```sh
export FOUNTAIN_BASE_URL="https://managoat.com"
export FOUNTAIN_API_KEY="the key from your start page"
export FOUNTAIN_AGENT_ID="the agent id from your start page"
```

For your own server, use that server's address as `FOUNTAIN_BASE_URL`.

!!! note "Whose model key"

    An agent calls a model. Fountain runs your agent on this deployment's own
    model key while your account has none. Your key always wins when you add
    one, under Account, then Inference keys. A server with no key of its own
    needs yours first, and your start page says which case you are in.

## 2. Send the request

```sh
--8<-- "docs/snippets/first-request.sh"
```

Fountain starts a sandbox, starts the agent in it, and answers. The response
holds the conversation `id`.

## 3. Read the reply

The reply arrives on your start page. For a terminal, read the conversation
stream with the id from step 2.

```sh
curl -N -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  "$FOUNTAIN_BASE_URL/api/conversations/CONVERSATION_ID/stream?blocks=true"
```

That reply came from your agent, on a machine that Fountain operates for you.
Fountain counts that moment as activation. It is the whole product, in one
request.

## The same request from the SDK

```bash
npm install @managoat/fountain-sdk@^5.2.0
```

```ts
--8<-- "docs/snippets/first-request.ts"
```

`new Fountain()` reads `FOUNTAIN_API_KEY` and `FOUNTAIN_BASE_URL` from the
environment, exactly as the CLI does. The request uses the same agent ID as
the curl example; copy it from your start page. `runRequest` accepts API fields
directly, with local timeout/event options passed separately. There are
[Python](python-sdk.md), [Elixir](elixir-sdk.md) and [Swift](swift-sdk.md)
clients over the same API.

## Where to go next

The [guided tour](tour.md) is the second page. It builds an agent that clones
your repository, changes it, and opens a pull request.

The rest of this page is the same first run from the CLI, and the way to run
the server yourself.

## Run your own server

You need Docker, OpenSSL, and a sandbox provider token. The Compose file runs
Postgres. The example below uses Sprites as the sandbox provider.

```sh
git clone https://github.com/managoat/fountain
cd fountain
cp .env.compose.example .env

echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" >> .env
echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" >> .env

# Add your SPRITES_TOKEN to .env, then start Fountain.
docker compose up -d
```

Open <http://localhost:4000>. Create the first operator account, then add an
Anthropic credential under Account, then Inference keys.

The Compose defaults self-verify the first account and make it the admin.
Create that account before you expose the server to another network. The
[deployment guide](guides/operate/deploy.md) shows how to verify readiness,
close registration, and configure the other sandbox providers.

## Install and authenticate the CLI

On macOS, install the CLI with Homebrew.

```sh
brew install managoat/tap/fountain
```

On Linux, Homebrew needs a C compiler before it installs a formula,
`build-essential` on Debian and Ubuntu. The release binary has no such need.

```sh
curl -fsSLo fountain \
  https://github.com/managoat/fountain/releases/latest/download/fountain-linux-amd64
chmod +x fountain
sudo mv fountain /usr/local/bin/
```

Use `fountain-linux-arm64` on an ARM machine.

Point the CLI at the server you chose.

```sh
# Your own server
FOUNTAIN_BASE_URL=http://localhost:4000 fountain auth login

# Hosted server
fountain auth login
```

`auth login` shows a one-time code and opens the console's approval page in
your browser. Approve the device there. The CLI saves the server URL and an
API key, so the commands below need no server flag.

## Apply and run your own agent

The request above runs the agent your account already has. A manifest
describes agents of your own, with the machine each one gets. Download the
small manifest, apply it, and call the agent by name.

```sh
curl -fsSLo fountain.yml \
  https://raw.githubusercontent.com/managoat/fountain/main/examples/quickstart/fountain.yml

fountain apply -f fountain.yml
fountain run fountain-reader -p \
  "Find the code that reclaims an idle sandbox. Explain when it runs and name the files you read."
```

**The clone already contains the manifest.** If you run your own server from
the checkout, skip the download. Apply `examples/quickstart/fountain.yml`
from the repository root, so the manifest matches the code you deployed.

`apply` creates two reusable rows. The Environment says which repository the
sandbox receives. The Agent says which runtime and model work in it.

`run` creates the Conversation. Fountain starts the sandbox, clones the
repository, starts Claude, and streams the work and final answer. The command
prints the conversation id first. Use it for a follow-up.

```sh
fountain conv prompt <conversation-id> -p \
  "Now trace the call one level deeper. What stops two reclaimers from racing?"
```

The follow-up lands on the same sandbox. The checkout and the agent session
are still there.

## What the example leaves out

The example has no Vault because it reads a public repository. Add a Vault
when a run needs a credential that changes independently from the machine or
the Agent. The [guided tour](tour.md) adds a GitHub token, changes a repository,
and opens a pull request.

The example uses Claude because it is Fountain's most exercised runtime. To
use Codex, Gemini CLI, or OpenCode, change `runtime` and `model` in the
manifest and add that provider's inference credential. The
[runtime catalog](catalog/runtimes/index.md) lists the accepted shapes.
