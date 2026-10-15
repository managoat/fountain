import { Managoat } from "@managoat/sdk";

const managoat = new Managoat();
const run = await managoat.runRequest({
  agent_id: "$MANAGOAT_AGENT_ID",
  prompt: "Which operating system and working directory are you in? Answer in one sentence.",
});

console.log(run.text);
