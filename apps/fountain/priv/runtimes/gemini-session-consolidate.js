#!/usr/bin/env node
// Keep one gemini chat-session file per session, outside the path its own
// loader will clobber. Workaround for google-gemini/gemini-cli#28775; delete
// this file and its call sites when that lands. Fountain issue: #659.
//
// The defect, in the version this was written against (0.53.0 through 0.56.0):
//
//   1. `session/load` builds a fresh config on the session id *before* looking
//      the session up, which stands up a chat recorder;
//   2. the recorder's new-session branch names its file
//      `session-${new Date().toISOString().slice(0,16)}-${id.slice(0,8)}.jsonl`
//      — minute resolution, so a load in the same minute as the last write
//      computes the *same path*;
//   3. it appends a `$set` carrying only its `<session_context>` bootstrap, and
//      the reader treats `$set.messages` as a replacement, not a merge;
//   4. the emptied file then fails `hasResumableContent` and is dropped from
//      `listSessions()`, so `findSession` reports "No previous sessions found
//      for this project" — about a session whose transcript is still on disk,
//      above the line that erased it.
//
// Renaming once is not enough. After every load, *two* files carry the same
// sessionId — the one we parked and the poisoned one the load just created —
// and gemini dedupes by id keeping the later `lastUpdated`, which is the
// poisoned one. So this consolidates instead: keep the file with real content,
// delete the poisoned duplicates, park the survivor under a name whose
// timestamp component can never be produced by the recorder.
//
// Discovery is unaffected: gemini's own scan filters only on the `session-`
// prefix and the extension, and matches sessions by the `sessionId` *inside*
// the file, never by the name.
//
// Usage: node gemini-session-consolidate.js <sessionId>
// Exits 0 on success or when there is nothing to do. Never throws for a
// missing directory: a turn that wrote no session is not an error.

const fs = require("fs");
const path = require("path");
const os = require("os");

const PARKED_STAMP = "0000-00-00T00-00";

function chatsDirs() {
  const base = path.join(process.env.HOME || os.homedir(), ".gemini", "tmp");
  let entries;
  try {
    entries = fs.readdirSync(base, { withFileTypes: true });
  } catch {
    return [];
  }
  const out = [];
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    const c = path.join(base, e.name, "chats");
    try {
      if (fs.statSync(c).isDirectory()) out.push(c);
    } catch {
      /* no chats dir for this project */
    }
  }
  return out;
}

// Mirrors gemini's own reader: records accumulate, but a `$set.messages`
// replaces everything seen so far. Only user/gemini records with content are
// resumable — which is exactly why a bootstrap-only `$set` reads as empty.
function inspect(file) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
  let sessionId = null;
  let messages = [];
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    let rec;
    try {
      rec = JSON.parse(t);
    } catch {
      continue;
    }
    if (!rec || typeof rec !== "object") continue;
    if (typeof rec.sessionId === "string" && !sessionId) sessionId = rec.sessionId;
    if (rec.$set && Array.isArray(rec.$set.messages)) {
      messages = rec.$set.messages.slice();
      continue;
    }
    if ((rec.type === "user" || rec.type === "gemini") && rec.content !== undefined) {
      messages.push(rec);
    }
  }
  const resumable = messages.filter(
    (m) => m && (m.type === "user" || m.type === "gemini") && m.content !== undefined
  ).length;
  return { sessionId, resumable };
}

function main() {
  const sid = process.argv[2];
  if (!sid) {
    process.stderr.write("usage: gemini-session-consolidate.js <sessionId>\n");
    process.exit(2);
  }
  const short = sid.slice(0, 8);
  let kept = 0;
  let removed = 0;

  for (const dir of chatsDirs()) {
    let names;
    try {
      names = fs.readdirSync(dir);
    } catch {
      continue;
    }
    const mine = [];
    for (const name of names) {
      if (!name.startsWith("session-") || !name.endsWith(".jsonl")) continue;
      const full = path.join(dir, name);
      const info = inspect(full);
      if (!info || info.sessionId !== sid) continue;
      mine.push({ full, name, resumable: info.resumable });
    }
    if (mine.length === 0) continue;

    // Richest wins; ties keep the already-parked file so repeated runs are
    // stable and a no-op turn cannot shuffle the archive.
    mine.sort((a, b) => {
      if (b.resumable !== a.resumable) return b.resumable - a.resumable;
      const ap = a.name.includes(PARKED_STAMP) ? 0 : 1;
      const bp = b.name.includes(PARKED_STAMP) ? 0 : 1;
      return ap - bp;
    });

    const best = mine[0];
    for (const f of mine.slice(1)) {
      try {
        fs.unlinkSync(f.full);
        removed++;
      } catch {
        /* already gone */
      }
    }

    const parked = path.join(dir, `session-${PARKED_STAMP}-${short}.jsonl`);
    if (path.resolve(best.full) !== path.resolve(parked)) {
      // rename, never onto a file we are still keeping — the losers are gone.
      fs.renameSync(best.full, parked);
    }
    kept++;
  }

  process.stdout.write(JSON.stringify({ sessionId: sid, kept, removed }) + "\n");
}

main();
