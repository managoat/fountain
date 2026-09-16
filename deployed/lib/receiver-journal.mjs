import { readFileSync, existsSync } from 'node:fs';
import { atomicJson } from './fixtures.mjs';

// Every receiver profile writes a journal beside its cleanup manifest —
// `receiver.json`, `mcp-receiver.json`, `webhook-receiver.json` — recording
// whether the run's records on that receiver still need deleting.
//
// A replay reads it to decide whether the receiver still owes anything. Two
// states mean it does not:
//
//   cleaned    the run deleted its records before it ended.
//   discarded  the receiver was hosted for the run and stopped with it, so
//              the instance holding those records no longer exists.
//
// Anything else is a receiver that may still be holding run records, which is
// an obligation a replay has to meet — and, for a receiver the operator hosts,
// still can.
export const TERMINAL = ['cleaned', 'discarded'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function read(path) {
  try {
    const journal = JSON.parse(readFileSync(path, 'utf8'));
    return journal && typeof journal === 'object' && !Array.isArray(journal) ? journal : undefined;
  } catch { return undefined; }
}

// Deliberately conservative: anything unreadable, mismatched or non-terminal
// answers false, which sends the caller down the path that demands the
// receiver's configuration. A journal cannot talk its way out of cleanup.
export function journalSettled(path, runId) {
  const journal = read(path);
  return Boolean(journal && journal.version !== undefined && UUID.test(runId) &&
    journal.run_id === runId && TERMINAL.includes(journal.state));
}

// Records that a receiver hosted for this run is gone. Its records went with
// the process, so nothing remains to delete — but a replay must be able to see
// that rather than infer it from a configuration that is also gone. A journal
// that already reached a terminal state is left exactly as it is.
export function discardJournal(path, runId) {
  if (!existsSync(path)) return false;
  const journal = read(path);
  if (!journal || journal.run_id !== runId || TERMINAL.includes(journal.state)) return false;
  atomicJson(path, { ...journal, state: 'discarded' });
  return true;
}
