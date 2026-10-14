import { test, describe } from "node:test";
import assert from "node:assert/strict";
import type { components } from "../src/generated/openapi.ts";

type AgentRequest = components["schemas"]["AgentRequest"];
type PermissionPolicy = NonNullable<AgentRequest["permission_policy"]>;

// A permission policy maps a tool title or ACP kind to a verdict. The one key
// whose value was a number, `ask_timeout`, went with the requests that
// outlived their turn (#2676), so every value is a verdict again.
describe("permission_policy", () => {
  test("a tool key takes a verdict", () => {
    const policy: PermissionPolicy = { default: "auto_allow", execute: "ask" };
    assert.equal(policy.execute, "ask");
  });

  test("a value that is not a verdict is refused", () => {
    // @ts-expect-error "maybe" is not a verdict.
    const policy: PermissionPolicy = { execute: "maybe" };
    assert.ok(policy);
  });

  test("a number is refused", () => {
    // @ts-expect-error `ask_timeout` is no longer a policy key.
    const policy: PermissionPolicy = { ask_timeout: 3600 };
    assert.ok(policy);
  });
});
