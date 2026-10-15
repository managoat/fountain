/**
 * The Node entry point.
 *
 * Everything the SDK does works in a browser, and `src/index.ts` is what a
 * bundler gets. The one thing that cannot work there is reading
 * `~/.managoat/credentials`, so that lives here: importing `@managoat/sdk`
 * under Node resolves to this module, which installs the reader and then
 * re-exports the same API.
 */
import { homedir } from "node:os";
import { join } from "node:path";
import { existsSync, readFileSync } from "node:fs";
import { env, parseCredentials, setCredentialsReader } from "./config.ts";

setCredentialsReader((profile) => {
  const override = env("MANAGOAT_CREDENTIALS_FILE");
  let path = override || join(homedir(), ".managoat", "credentials");
  // The file was ~/.fountain/credentials before ADR 0082, and the CLI keeps
  // reading it until its first write creates the new one.
  if (!override && !existsSync(path)) path = join(homedir(), ".fountain", "credentials");
  return parseCredentials(readFileSync(path, "utf8"), profile);
});

export * from "./index.ts";
export { default } from "./index.ts";
