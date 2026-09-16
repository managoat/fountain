import { ensure, history } from './execution.mjs';
import { streamEvents } from './sse.mjs';
import { isDeepStrictEqual } from 'node:util';

const shared = ['id', 'kind', 'stream', 'data', 'stage', 'state', 'turn_id', 'ts', 'blocks'];
const projection = event => Object.fromEntries(shared.filter(key => Object.hasOwn(event, key)).map(key => [key, event[key]]));

export function compareEvents(actual, expected, { after = 0, through }) {
  ensure(Number.isSafeInteger(after) && after >= 0 && Number.isSafeInteger(through) && through >= after, 'Invalid replay comparison bounds');
  ensure(expected.some(event => event.id === through), 'History does not contain the durable high-water event');
  let cursor = after;
  for (const event of actual) {
    ensure(Number.isSafeInteger(event.id) && event.id > cursor, 'Replay duplicated, reordered, or ignored the requested cursor');
    cursor = event.id;
  }
  const received = actual.filter(e => e.id <= through);
  const stored = expected.filter(e => e.id > after && e.id <= through);
  ensure(received.length === stored.length, `Stream/history event count differs (${received.length}/${stored.length})`);
  for (let i = 0; i < stored.length; i++) {
    const actual = projection(received[i]), expected = projection(stored[i]);
    const differences = shared.filter(key => Object.hasOwn(actual, key) !== Object.hasOwn(expected, key) || !isDeepStrictEqual(actual[key], expected[key]));
    ensure(differences.length === 0, `Stream/history payload differs at event ${stored[i].id} (${differences.join(', ')})`);
  }
  return stored.length;
}

export async function verifyReplay(ctx, conversationId, first, second, signal) {
  // Small enough that any real conversation spans pages, large enough to stay cheap.
  const paginated = await history(ctx.client, conversationId, signal, 25);
  ensure(paginated.pages > 1, 'Fixture did not exercise history pagination');
  Object.assign(ctx.report.streaming, { history_pages: paginated.pages, high_water_cursor: second.cursor });
  const all = [];
  for await (const { event } of streamEvents(ctx.client, `/api/conversations/${conversationId}/stream?blocks=true&wait=false`, { signal })) all.push(event);
  const count = compareEvents(all, paginated.events, { through: second.cursor });
  ctx.report.streaming.replay_events_compared = count;
  const after = ctx.report.streaming.reconnect_cursor;
  const resumed = [];
  for await (const { event } of streamEvents(ctx.client, `/api/conversations/${conversationId}/stream?blocks=true&wait=false`, { signal, after })) resumed.push(event);
  ctx.report.streaming.resumed_replay_events_compared = compareEvents(resumed, paginated.events, { after, through: second.cursor });
  ctx.report.streaming.wait_false_closed = true;
  const live = [...first.events, ...second.events].map(frame => frame.event);
  const liveCount = compareEvents(live, paginated.events, { after: ctx.report.streaming.provision_cursor, through: second.cursor });
  ctx.report.streaming.live_events_compared = liveCount;
}
