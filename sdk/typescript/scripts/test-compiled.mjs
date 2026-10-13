#!/usr/bin/env node
// Exercise the same tests on runtimes that cannot execute TypeScript directly.
import { cpSync, mkdirSync, mkdtempSync, readdirSync, rmSync, symlinkSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const sdk = join(dirname(fileURLToPath(import.meta.url)), "..");
if (process.argv.length > 2) throw new Error("usage: node scripts/test-compiled.mjs");
const temporary = mkdtempSync(join(tmpdir(), "fountain-sdk-tests-"));
const output = join(temporary, "sdk", "typescript");
try {
  mkdirSync(output, { recursive: true });
  execFileSync(process.execPath, [join(sdk, "node_modules/typescript/lib/tsc.js"),
    "-p", join(sdk, "tsconfig.json"), "--outDir", output], { cwd: sdk, stdio: "inherit" });
  // Keep the tests' relative fixture paths and source/package inspections.
  cpSync(join(sdk, "src"), join(output, "src"), { recursive: true });
  cpSync(join(sdk, "package.json"), join(output, "package.json"));
  // A test that imports a package resolves it from the copy, not from here.
  // rmSync unlinks the symlink without following it into the real directory.
  symlinkSync(join(sdk, "node_modules"), join(output, "node_modules"), "dir");
  cpSync(join(sdk, "test", "scenarios"), join(output, "test", "scenarios"), { recursive: true });
  cpSync(join(sdk, "..", "contract"), join(temporary, "sdk", "contract"), { recursive: true });
  const tests = readdirSync(join(output, "test")).filter(name => name.endsWith(".test.js")).sort();
  if (!tests.length) throw new Error("No compiled SDK tests found");
  const result = spawnSync(process.execPath, ["--test", ...tests.map(name => join(output, "test", name))],
    { cwd: output, stdio: "inherit" });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
