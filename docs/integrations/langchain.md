# LangChain and Deep Agents (retired)

Fountain used to fit into [LangChain](https://github.com/langchain-ai/langchain)
and [Deep Agents](https://github.com/langchain-ai/deepagents) as a **subagent**:
a `FountainAgent` runnable in one Python file, talking to Fountain over the
[OpenAI-compatible API](openai-compatible.md) as a `ChatOpenAI` model, with a
LangGraph `thread_id` mapped to a sandbox. **That API is gone**, removed in
the release that carries
[ADR 0057](https://github.com/managoat/fountain/blob/main/decisions/0057-retire-public-compatibility-protocols.md),
and the integration and its `examples/deepagents-contractor` example went with
it.

This page stays because the URL is in other people's notes.

## What has no replacement

Be clear about the size of this, because it is the biggest thing the
retirement costs:

- **A stock `ChatOpenAI` pointed at Fountain.** The integration worked because
  Fountain spoke a dialect LangChain already had a client for. It does not any
  more, so there is no base URL to swap in.
- **The `role: "tool"` continuation loop.** LangChain's tool calling returned
  results to Fountain as chat messages, and the request-defined tool bridge
  turned those into answers for the agent. Both halves are retired
  (ADR 0057). Fountain's native API has no equivalent: an agent's tools are
  configured on the agent, not defined per request by the caller.

Nothing in the native API gives either of those back, and this page is not
going to pretend otherwise.

## What you can still do

Drive Fountain from Python directly, with the
[conversation API](../api.md): create a
conversation for the work, prompt it, follow its stream, read the result, and
hand that back to your orchestrator yourself. That replaces the *delegation*
— an orchestrator handing work to a Fountain agent and reading its report —
which is what most people used this for. It is a wrapper you write, not a
model object LangChain already understands.

If the Fountain agent needs to call back into your application mid-run,
configure that as an MCP server **on the agent**, with `${VAR}` references
resolved from the environment and the vault. That path is fully supported and
is not the retired bridge. Read [Plug into Fountain](clients.md).
