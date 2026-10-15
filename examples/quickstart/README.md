# Managoat quickstart

This is the smallest Managoat manifest that demonstrates a real sandbox. It
clones Managoat's public repository and gives a Claude agent the checkout. It
has no setup script, packages, Vault, or repository credential.

Once a Managoat server is running, authenticate the `managoat` CLI against
that server and add an Anthropic credential to your operator account. Then run
these two commands from the repository root.

```sh
managoat apply -f examples/quickstart/managoat.yml
managoat run fountain-reader -p \
  "Find the code that reclaims an idle sandbox. Explain when it runs and name the files you read."
```

The first command creates one Environment and one Agent. The second starts a
sandbox, clones the repository, runs the agent, and streams the answer back to
the terminal.

Read [Deploy an instance](../../docs/guides/operate/deploy.md) to run the
server yourself, and [Use the CLI](../../docs/cli.md#install) to install and
authenticate the CLI.
