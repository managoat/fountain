#!/usr/bin/env node
/**
 * Check this SDK's declared wire dependencies against the server's contract.
 *
 * `sdk/contract/contract.json` is the projection of the server's OpenAPI
 * document; `sdk/contract/manifests/typescript.json` is what this client says
 * it depends on. Everything named there must still exist, still be required if
 * this client relies on it being present, still be optional if this client
 * relies on being able to omit it, and still accept every enum value this
 * client sends or switches on.
 *
 * The generated types in `src/generated/openapi.ts` cover the whole document
 * and `npm run generate` proves they are current. This is the other half: the
 * hand-written layer above them — `run`, the resources, the turn follower —
 * reaches for wire fields by name, and no type check catches a field that
 * moved out from under a template string.
 *
 * A future client runs the same checks from its own manifest;
 * `sdk/contract/README.md` is the spec.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const SDK = "typescript";
const here = dirname(fileURLToPath(import.meta.url));
const contractDir = join(here, "..", "..", "contract");

const read = (path, what) => {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    console.error(`error: cannot read ${what} (${path}): ${error.message}`);
    process.exit(1);
  }
};

const contract = read(join(contractDir, "contract.json"), "the wire contract");
const manifest = read(join(contractDir, "manifests", `${SDK}.json`), "the SDK manifest");

const problems = [];
const fail = (scenario, detail) => problems.push({ scenario, detail });

// ── operations ───────────────────────────────────────────────────────────────

for (const operation of manifest.operations ?? []) {
  if (!(operation in contract.operations)) {
    fail(
      `operation ${operation}`,
      "the API no longer serves it. Update the client, or drop it from the manifest.",
    );
  }
}

// ── schemas and their fields ─────────────────────────────────────────────────

for (const [name, declared] of Object.entries(manifest.schemas ?? {})) {
  const schema = contract.schemas[name];
  if (!schema) {
    fail(`schema ${name}`, "the API no longer defines it.");
    continue;
  }
  const properties = schema.properties ?? {};

  const check = (field, expectation) => {
    const property = properties[field];
    if (!property) {
      fail(
        `${name}.${field}`,
        `the API no longer has this property. It has: ${Object.keys(properties).sort().join(", ")}`,
      );
      return;
    }
    if (expectation === "required" && property.required !== true) {
      fail(
        `${name}.${field}`,
        "this client reads it as always present, but the API no longer requires it.",
      );
    }
    if (expectation === "optional" && property.required === true) {
      fail(
        `${name}.${field}`,
        "this client omits it, but the API now requires it.",
      );
    }
  };

  for (const field of declared.required ?? []) check(field, "required");
  for (const field of declared.optional ?? []) check(field, "optional");
  for (const field of declared.fields ?? []) check(field, "present");
}

// ── enum values ──────────────────────────────────────────────────────────────

for (const [path, declared] of Object.entries(manifest.enums ?? {})) {
  const [name, field] = path.split(".");
  const property = contract.schemas[name]?.properties?.[field];
  if (!property) {
    fail(`enum ${path}`, "the API no longer has this property.");
    continue;
  }
  if (!Array.isArray(property.enum)) {
    fail(`enum ${path}`, "the API no longer constrains this property to an enum.");
    continue;
  }
  const values = Array.isArray(declared) ? declared : (declared.values ?? []);
  const missing = values.filter((value) => !property.enum.includes(value));
  if (missing.length > 0) {
    fail(
      `enum ${path}`,
      `this client handles ${missing.join(", ")}, which the API no longer accepts. ` +
        `It now accepts: ${property.enum.join(", ")}`,
    );
  }
  if (!Array.isArray(declared) && declared.exhaustive === true) {
    const extra = property.enum.filter((value) => !values.includes(value));
    if (extra.length > 0) {
      fail(
        `enum ${path}`,
        `this client claims to handle every value but the API added: ${extra.join(", ")}`,
      );
    }
  }
}

// ── report ───────────────────────────────────────────────────────────────────

if (problems.length > 0) {
  console.error(`SDK contract check FAILED for ${SDK} (${problems.length} problems)\n`);
  for (const { scenario, detail } of problems) {
    console.error(`  ${scenario}`);
    console.error(`      ${detail}\n`);
  }
  console.error(
    "The server's wire contract moved. Update sdk/typescript to match, then\n" +
      "adjust sdk/contract/manifests/typescript.json. See sdk/contract/README.md.",
  );
  process.exit(1);
}

const counts =
  `${(manifest.operations ?? []).length} operations, ` +
  `${Object.keys(manifest.schemas ?? {}).length} schemas, ` +
  `${Object.keys(manifest.enums ?? {}).length} enums`;
console.log(`SDK contract check ok for ${SDK} (${counts})`);
