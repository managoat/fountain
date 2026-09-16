import { setTimeout as sleep } from 'node:timers/promises';
import { streamEvents } from './sse.mjs';

export function phaseSignal(parent, ms) { return AbortSignal.any([parent, AbortSignal.timeout(ms)]); }
export function ensure(ok, message) { if (!ok) throw new Error(message); }

// The budget counts events, not pages, so a small page size cannot shrink the
// transcript it reads. A thinking model streams a chunk per token.
export async function history(client, id, signal, pageSize = 100, maxEvents = 10000) {
  const events = [], maxPages = Math.ceil(maxEvents / pageSize);
  let cursor = 0, pages = 0;
  while (true) {
    if (++pages > maxPages) throw new Error(`Event history exceeded its ${maxEvents}-event budget`);
    const { body } = await client.request('GET', `/api/conversations/${id}/events?blocks=true&limit=${pageSize}&after=${cursor}`, { expected: 200, signal });
    for (const event of body.data) {
      ensure(event.id > cursor, 'History cursor did not advance in order');
      cursor = event.id; events.push(event);
    }
    if (!body.meta.has_more) return { events, pages };
    ensure(body.data.length > 0 && body.meta.next_cursor === cursor, 'History pagination is stuck');
  }
}

export async function waitFor(client, path, signal, accept) {
  while (true) {
    const { body } = await client.request('GET', path, { expected: 200, signal });
    if (accept(body.data)) return body.data;
    await sleep(250, undefined, { signal });
  }
}

export async function watchUntil(client, id, signal, accept, options = {}) {
  const events = [];
  let cursor = options.after ?? 0;
  for await (const frame of streamEvents(client, `/api/conversations/${id}/stream?blocks=true`, { signal, ...options })) {
    const event = frame.event;
    ensure(event.id > cursor, 'Live SSE event IDs did not advance');
    cursor = event.id; events.push(frame);
    if (event.kind === 'stage' && ['failed', 'interrupted'].includes(event.state)) {
      throw new Error(`Conversation ${id}: ${event.stage}/${event.state} (see event trace)`);
    }
    if (await accept(event, frame)) return { events, cursor };
  }
  throw new Error(`Conversation ${id}: stream closed before the expected stage`);
}

export function turnMetadata(event) {
  if (event.kind !== 'stage' || event.stage !== 'turn') return null;
  try { return JSON.parse(event.data); } catch { throw new Error('Turn stage metadata is not JSON'); }
}

export async function performTurn(ctx, conversation, prompt, number, after, { verifyStreaming = false, submit } = {}) {
  const startedMs = performance.now();
  const signal = phaseSignal(ctx.signal, ctx.config.execution.turn_ms);
  ctx.fixtures.reserveTurn(conversation.id, ctx.config.execution.max_turns);
  const queued = submit ? await submit({ prompt, signal }) :
    await ctx.client.request('POST', `/api/conversations/${conversation.id}/prompts`, { body: { prompt }, expected: 200, signal });
  ensure(queued.body.status === 'queued', 'Prompt was not acknowledged as queued');
  let startedId;
  const isDone = event => {
    const meta = turnMetadata(event);
    if (meta?.turn_number !== number) return false;
    if (event.state === 'started') startedId = meta.turn_id ?? event.turn_id;
    return event.state === 'done';
  };
  let streamed;
  if (verifyStreaming) {
    const initial = await watchUntil(ctx.client, conversation.id, signal, async (event, frame) => {
      if (isDone(event)) throw new Error('Turn completed before incremental output could be verified');
      if (event.kind !== 'output' || !startedId || event.turn_id !== startedId) return false;
      const { body } = await ctx.client.request('GET', `/api/conversations/${conversation.id}/turns`, { expected: 200, signal });
      ensure(body.data.some(turn => turn.id === startedId && turn.status === 'running'), 'Output arrived after the turn finished; ingress may be buffering SSE');
      ctx.report.streaming = { provision_cursor: after, reconnect_cursor: event.id,
        observed_running_turn_id: startedId, output_received_ms: frame.receivedMs - startedMs, incremental_output_verified: true };
      return true;
    }, { after });
    // Let at least one persisted event be missed while disconnected. Then the
    // reconnect must replay it before entering the live tail.
    const missed = await waitFor(ctx.client, `/api/conversations/${conversation.id}/events?after=${initial.cursor}&limit=1&blocks=true`, signal, events => events.length > 0);
    ensure(missed[0].id > initial.cursor, 'No durable event accumulated during the disconnection');
    ctx.report.streaming.missed_event_id = missed[0].id;
    const resumed = await watchUntil(ctx.client, conversation.id, signal, isDone, { after: initial.cursor });
    ensure(resumed.events.some(frame => frame.event.id === missed[0].id), 'Reconnect lost the event persisted while disconnected');
    streamed = { cursor: resumed.cursor, events: [...initial.events, ...resumed.events] };
    ctx.report.streaming.resumed_events = resumed.events.length;
  } else streamed = await watchUntil(ctx.client, conversation.id, signal, isDone, { after });
  ensure(typeof startedId === 'string', `Turn ${number} had no start event`);
  const turns = await waitFor(ctx.client, `/api/conversations/${conversation.id}/turns`, signal, rows =>
    rows.some(row => row.turn_number === number && row.status === 'completed'));
  ensure(turns.length === number, 'Unexpected additional inference turn');
  const turn = turns.find(t => t.turn_number === number);
  ensure(turn.id === startedId && turn.prompt === prompt, 'Turn identity/prompt disagrees with accepted work');
  ensure(turn.exit_code === 0 || turn.exit_code === null, 'Completed turn has a nonzero exit code');
  const stored = await history(ctx.client, conversation.id, signal);
  const ownEvents = stored.events.filter(event => event.turn_id === turn.id);
  const tools = ownEvents.flatMap(event => event.blocks ?? []).filter(block => block.kind === 'tool_use');
  ensure(tools.length > 0, `Turn ${number} produced no persisted tool activity`);
  ctx.report.execution.turns.push({ id: turn.id, number, status: turn.status, usage: turn.usage ?? null, tools: tools.map(t => t.name) });
  return { ...streamed, turn, stored: stored.events };
}
