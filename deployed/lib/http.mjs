export class Redactor {
  constructor(secrets = []) { this.secrets = new Set(secrets.filter(Boolean)); }
  add(value) { if (typeof value === 'string' && value) this.secrets.add(value); }
  text(value) {
    let result = String(value);
    for (const secret of [...this.secrets].sort((a, b) => b.length - a.length)) result = result.replaceAll(secret, '[REDACTED]');
    return result.replace(/ftn_[A-Za-z0-9_-]+/g, '[REDACTED]');
  }
  value(value) {
    if (typeof value === 'string') return this.text(value);
    if (Array.isArray(value)) return value.map(item => this.value(item));
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => {
      if (/(?:key$|token|secret|password|authorization|cookie|credential|^value$|email)/i.test(key)) {
        this.collect(item);
        return [key, '[REDACTED]'];
      }
      return [key, this.value(item)];
    }));
    return value;
  }
  collect(value) {
    if (typeof value === 'string') this.add(value);
    else if (value && typeof value === 'object') Object.values(value).forEach(item => this.collect(item));
  }
  // For data the suite composed itself, rather than data an instance sent us.
  //
  // `value` guesses at credentials from key names, which is right for a
  // response body and wrong for the report: its evidence lives under keys like
  // `secrets` and `credential_keys`, so the guess replaced whole findings with
  // "[REDACTED]" and, worse, `collect` promoted every string inside them to a
  // redaction token. A leak record carries `transport: "sse"`, which then
  // rewrote every later "passed" into "pa[REDACTED]d" — corrupting check
  // statuses in result.json and the failure counts junit.xml derives from them.
  //
  // Registered secrets are still removed from every string here. Nothing in
  // the report arrives unregistered: values the suite generated are added
  // explicitly, and anything read from the instance already passed through
  // `value` on the way in.
  strings(value) {
    if (typeof value === 'string') return this.text(value);
    if (Array.isArray(value)) return value.map(item => this.strings(item));
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, this.strings(item)]));
    }
    return value;
  }
}

export class Client {
  constructor({ baseUrl, key, redactor, trace, signal, timeoutMs = 10000, contract }) {
    Object.assign(this, { baseUrl, key, redactor, trace, signal, timeoutMs, contract });
  }
  async request(method, path, { body, key = this.key, expected, validate = true, recordBody = true, signal = this.signal } = {}) {
    if (!path.startsWith('/') || path.startsWith('//') || path.includes('..')) throw new Error('Expected a relative API path');
    const started = performance.now();
    const headers = { accept: 'application/json' };
    if (key) headers.authorization = `Bearer ${key}`;
    if (body !== undefined) headers['content-type'] = 'application/json';
    this.redactor.add(key);
    if (body) this.redactor.value(body);
    const timer = AbortSignal.timeout(this.timeoutMs);
    const combined = signal ? AbortSignal.any([signal, timer]) : timer;
    let response;
    try {
      response = await fetch(this.baseUrl + path, {
        method, headers, body: body === undefined ? undefined : JSON.stringify(body),
        redirect: 'manual', signal: combined,
      });
      const reader = response.body?.getReader();
      const chunks = [];
      let size = 0;
      if (reader) {
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            size += value.length;
            if (size > 2 * 1024 * 1024) throw new Error('Response exceeds 2 MiB');
            chunks.push(value);
          }
        } finally { await reader.cancel().catch(() => {}); }
      }
      const raw = Buffer.concat(chunks).toString('utf8');
      let json;
      if (raw) {
        try { json = JSON.parse(raw); } catch { throw new Error('Response is not JSON'); }
        if (!/^application\/json(?:;|$)/i.test(response.headers.get('content-type') ?? '')) throw new Error('Response is not application/json');
      }
      // Collect secrets throughout the body before redacting sibling fields.
      if (recordBody) this.redactor.value(json);
      this.trace({ method, path, status: response.status, duration_ms: performance.now() - started,
        request_id: response.headers.get('x-request-id'), body: recordBody ? this.redactor.value(json) : undefined, response_bytes: size });
      this.assertPublicSafe?.(json, { path, transport: 'http' });
      if (expected !== undefined && ![expected].flat().includes(response.status)) {
        throw new Error(`${method} ${path}: expected ${[expected].flat().join('/')} but received ${response.status}`);
      }
      if (validate) this.contract?.check(method, path, response.status, json);
      return { status: response.status, body: json };
    } catch (error) {
      this.trace({ method, path, status: response?.status, duration_ms: performance.now() - started,
        error: this.redactor.text(combined.aborted ? 'Request deadline or cancellation' : error.message) });
      throw new Error(combined.aborted ? `${method} ${path}: deadline or cancellation` : this.redactor.text(error.message));
    }
  }
}
