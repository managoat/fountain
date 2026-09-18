#!/usr/bin/env node
/**
 * The facts about an SDK release, in one place, so the PR gate and the publish
 * workflow cannot disagree about them.
 *
 *   node scripts/sdk-release.mjs state          → JSON on stdout
 *   node scripts/sdk-release.mjs guard <base>   → the PR gate; exits 1 on a problem
 *
 * No dependencies: this runs before `npm ci` in at least one caller.
 */
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const PKG_DIR = "sdk/typescript";

/** Files whose contents reach a consumer. Changing one needs a release. */
const PUBLISHED_GLOBS = [`${PKG_DIR}/src/`, `${PKG_DIR}/package.json`, `${PKG_DIR}/LICENSE`];

/**
 * The manifest fields a consumer is actually affected by.
 *
 * `package.json` ships, so a naive rule calls every edit to it a release —
 * including `scripts`, which exists only for this repository, and
 * `devDependencies`, which nobody installing the package ever resolves.
 * Comparing this projection instead means the gate fires on a changed export
 * map or a dropped Node engine, and stays quiet for repository plumbing.
 */
const CONSUMER_FIELDS = [
  "name",
  "version",
  "type",
  "exports",
  "main",
  "types",
  "browser",
  "bin",
  "files",
  "engines",
  "license",
  "sideEffects",
  "dependencies",
  "peerDependencies",
  "optionalDependencies",
];

const consumerFacing = (pkg) =>
  JSON.stringify(Object.fromEntries(CONSUMER_FIELDS.map((k) => [k, pkg[k] ?? null])));

/**
 * Files inside the package that a consumer never receives. Tests, examples and
 * the changelog are excluded on purpose — requiring a version bump to write the
 * changelog entry for that very version is a loop with no entrance.
 */
const UNPUBLISHED = (path) =>
  path.startsWith(`${PKG_DIR}/test/`) ||
  path.startsWith(`${PKG_DIR}/examples/`) ||
  path === `${PKG_DIR}/CHANGELOG.md` ||
  path === `${PKG_DIR}/tsconfig.json` ||
  path === `${PKG_DIR}/tsconfig.build.json` ||
  path === `${PKG_DIR}/package-lock.json`;

const manifest = (ref) => {
  const raw =
    ref === null
      ? readFileSync(`${PKG_DIR}/package.json`, "utf8")
      : git(["show", `${ref}:${PKG_DIR}/package.json`]);
  return JSON.parse(raw);
};

function git(args) {
  return execFileSync("git", args, { encoding: "utf8" });
}

/** Whether the registry already has this exact version. */
async function isPublished(name, version) {
  const url = `https://registry.npmjs.org/${name.replace("/", "%2F")}/${version}`;
  const response = await fetch(url, { headers: { accept: "application/json" } });
  if (response.status === 200) return true;
  if (response.status === 404) return false;
  throw new Error(`registry answered ${response.status} for ${name}@${version}`);
}

async function state() {
  const pkg = manifest(null);
  return {
    name: pkg.name,
    version: pkg.version,
    published: await isPublished(pkg.name, pkg.version),
    tag: `sdk-typescript-v${pkg.version}`,
  };
}

function fail(message) {
  console.error(`::error::${message}`);
  process.exitCode = 1;
}

async function guard(baseRef) {
  const changed = git(["diff", "--name-only", `${baseRef}...HEAD`]).split("\n").filter(Boolean);
  const touched = changed.filter((p) => p.startsWith(`${PKG_DIR}/`));
  const head = manifest(null);
  const base = manifest(baseRef);
  const bumped = head.version !== base.version;

  const manifestMattersToConsumers = consumerFacing(head) !== consumerFacing(base);
  const needsRelease = touched.filter((p) => {
    if (UNPUBLISHED(p)) return false;
    // package.json ships, but most of what changes in it is repository-only.
    if (p === `${PKG_DIR}/package.json`) return manifestMattersToConsumers;
    return PUBLISHED_GLOBS.some((g) => p.startsWith(g));
  });

  console.log(`package:  ${head.name}`);
  console.log(`base:     ${base.version}`);
  console.log(`head:     ${head.version}${bumped ? "  (bumped)" : "  (unchanged)"}`);
  console.log(`touched:  ${touched.length} file(s) under ${PKG_DIR}`);
  if (needsRelease.length) console.log(`shipped:  ${needsRelease.join(", ")}`);

  if (needsRelease.length && !bumped) {
    fail(
      `This PR changes what the SDK ships (${needsRelease.join(", ")}) but leaves the ` +
        `version at ${head.version}. Nothing publishes without a bump, so the change would ` +
        `sit on main unreleased. Run \`cd ${PKG_DIR} && npm version patch\` (or minor/major), ` +
        `update USER_AGENT and CHANGELOG.md, and commit. To change the published surface ` +
        `without releasing, add the "release:skip-sdk" label.`,
    );
    return;
  }

  if (!bumped) {
    console.log("\nNo release needed for this PR.");
    return;
  }

  // From here on the PR claims a release, so everything that would make the
  // publish fail on main is checked here instead — where it is still cheap.
  if (await isPublished(head.name, head.version)) {
    fail(
      `${head.name}@${head.version} is already on npm, and npm never allows a version to be ` +
        `republished. Bump to something new.`,
    );
  }

  const changelog = readFileSync(`${PKG_DIR}/CHANGELOG.md`, "utf8");
  if (!changelog.includes(`## [${head.version}]`)) {
    fail(`CHANGELOG.md has no "## [${head.version}]" heading. A release says what changed.`);
  }

  const http = readFileSync(`${PKG_DIR}/src/http.ts`, "utf8");
  if (!http.includes(`fountain-sdk-js/${head.version}`)) {
    fail(
      `USER_AGENT in ${PKG_DIR}/src/http.ts still does not say ${head.version}. ` +
        `\`npm version\` does not touch it.`,
    );
  }

  if (process.exitCode !== 1) {
    console.log(`\nRelease looks well-formed. Merging this publishes ${head.version}.`);
  }
}

const [command, arg] = process.argv.slice(2);

if (command === "state") {
  console.log(JSON.stringify(await state(), null, 2));
} else if (command === "guard") {
  if (!arg) {
    console.error("usage: sdk-release.mjs guard <base-ref>");
    process.exit(2);
  }
  await guard(arg);
} else {
  console.error("usage: sdk-release.mjs state | guard <base-ref>");
  process.exit(2);
}
