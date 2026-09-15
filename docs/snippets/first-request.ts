import { Fountain } from "@managoat/fountain-sdk";

const fountain = new Fountain();
const run = await fountain.runRequest({
  agent_id: "$FOUNTAIN_AGENT_ID",
  prompt: "Which operating system and working directory are you in? Answer in one sentence.",
});

console.log(run.text);
