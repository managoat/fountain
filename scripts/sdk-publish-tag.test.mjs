import assert from "node:assert/strict";
import test from "node:test";
import { publishTag, registryState } from "./sdk-publish-tag.mjs";

const registry = (...versions) => ({ versions: Object.fromEntries(versions.map((v) => [v, {}])) });

test("numeric version order, prereleases and backports", () => {
  assert.equal(publishTag("1.10.0", registry("1.9.9")), "latest");
  assert.equal(publishTag("2.0.0", registry("1.99.99")), "latest");
  assert.equal(publishTag("1.18.0", registry("1.19.0")), "backport");
  assert.equal(publishTag("1.19.0", registry("1.19.0")), "backport");
  assert.equal(publishTag("1.19.0+build.2", registry("1.19.0+build.1")), "backport");
  assert.equal(publishTag("2.0.0-rc.1", registry("1.19.0")), "next");
  assert.equal(publishTag("1.20.0", registry("2.0.0-rc.1", "1.19.0")), "latest");
  assert.equal(publishTag("0.1.0", registry()), "latest");
});

test("all six release orders leave latest on the highest stable version", () => {
  const versions = ["1.17.0", "1.18.0", "1.19.0"];
  for (const first of versions) {
    for (const second of versions.filter((v) => v !== first)) {
      const third = versions.find((v) => v !== first && v !== second);
      const state = { ...registry("1.16.0"), "dist-tags": { latest: "1.16.0" } };
      for (const version of [first, second, third]) {
        const tag = publishTag(version, state);
        state.versions[version] = {};
        state["dist-tags"][tag] = version;
      }
      assert.equal(state["dist-tags"].latest, "1.19.0");
      assert.equal(Object.keys(state.versions).length, 4);
    }
  }
});

test("a newer latest tag protects against an incomplete versions listing", () => {
  assert.equal(publishTag("1.18.0", { ...registry("1.17.0"), "dist-tags": { latest: "1.19.0" } }), "backport");
});

test("registry errors and malformed data fail closed", async () => {
  for (const body of [null, {}, { versions: null }, { versions: [] }]) {
    assert.throws(() => publishTag("1.18.0", body), /versions map/);
  }
  await assert.rejects(registryState("@managoat/sdk", async () => new Response("unavailable", { status: 503 })), /503/);
  await assert.rejects(registryState("@managoat/sdk", async () => new Response("not JSON")), SyntaxError);
  assert.deepEqual(await registryState("@managoat/sdk", async (url) => {
    assert.equal(url, "https://registry.npmjs.org/%40managoat%2Fsdk");
    return new Response("missing", { status: 404 });
  }), { versions: {} });
});
