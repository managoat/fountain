'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const tls = require('node:tls');
const { execFileSync } = require('node:child_process');
const relay = process.env.FOUNTAIN_RELAY_TEST_SOURCE ||
  path.resolve(__dirname, '../priv/broker/transport-relay.cjs');

async function fixture(t, respond) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-liveness-'));
  const cert = path.join(directory, 'cert.pem');
  const key = path.join(directory, 'key.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost'], { stdio: 'ignore' });
  const sockets = new Set();
  const timers = new Set();
  const server = tls.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert) }, s => {
    s.on('error', () => {});
    s.once('data', data => respond(s, data, timers));
  });
  server.on('connection', s => {
    sockets.add(s);
    s.on('close', () => sockets.delete(s));
  });
  server.on('tlsClientError', () => {});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const reservation = net.createServer();
  await new Promise(resolve => reservation.listen(0, '127.0.0.1', resolve));
  const listen = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const config = JSON.stringify({ host: 'localhost', port: server.address().port,
    listen, owner: 'liveness-test', ca: cert, controlDirectory: path.join(directory, 'control') });
  t.after(async () => {
    try { execFileSync(process.execPath, [relay, 'stop', config], { timeout: 15_000 }); }
    finally {
      for (const timer of timers) clearTimeout(timer);
      for (const s of sockets) s.destroy();
      await new Promise(resolve => server.close(resolve));
      fs.rmSync(directory, { recursive: true, force: true });
    }
  });
  // The supervisor's TLS readiness handshake requires this process's event loop.
  await new Promise((resolve, reject) => {
    require('node:child_process').execFile(process.execPath, [relay, 'ensure', config],
      { timeout: 15_000 }, error => error ? reject(error) : resolve());
  });
  return listen;
}

async function request(port, timeout = 25_000) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1', () => socket.write('request'));
    let response = '';
    const started = performance.now();
    socket.setTimeout(timeout, () => socket.destroy(new Error('test deadline exceeded')));
    socket.on('data', data => { response += data; });
    socket.on('error', reject);
    socket.on('close', () => resolve({ response, elapsed: performance.now() - started }));
  });
}

test('healthy TCP peer can take longer than the keepalive failure window to respond',
  { timeout: 35_000 }, async t => {
    const port = await fixture(t, (s, data, timers) => {
      timers.add(setTimeout(() => s.end(data), 18_000));
    });
    const result = await request(port);
    assert.equal(result.response, 'request');
    assert.ok(result.elapsed >= 18_000);
  });

// Explicit opt-in, only in an isolated network namespace. Never changes the
// host firewall. Run from the repository root:
// sudo unshare --net sh -c 'ip link set lo up; FOUNTAIN_RELAY_FAULT_TEST=1 node --test apps/fountain/test/broker_transport_liveness.test.cjs'
test('lost return path closes the local connection promptly and a fresh connection recovers',
  { timeout: 35_000, skip: process.env.FOUNTAIN_RELAY_FAULT_TEST !== '1' }, async t => {
    assert.notEqual(fs.readlinkSync('/proc/self/ns/net'), fs.readlinkSync('/proc/1/ns/net'),
      'refusing to change firewall in the host network namespace');
    let rule;
    let attempts = 0;
    const port = await fixture(t, (s, data, timers) => {
      if (++attempts > 1) { s.end(data); return; }
      // Allow the kernel's request ACK, then drop all return traffic for only
      // this established flow. The peer stays alive; neither FIN nor RST can
      // inform the relay. Subsequent keepalive ACKs are also lost.
      timers.add(setTimeout(() => {
        rule = ['OUTPUT', '-p', 'tcp', '--sport', String(s.localPort),
          '--dport', String(s.remotePort), '-j', 'DROP'];
        execFileSync('iptables', ['-A', ...rule]);
        s.write('response that never reaches the relay');
      }, 200));
    });
    t.after(() => { if (rule) execFileSync('iptables', ['-D', ...rule]); });
    const result = await request(port);
    assert.equal(result.response, '');
    assert.ok(result.elapsed >= 5000, `closed too early: ${result.elapsed}ms`);
    assert.ok(result.elapsed < 22_000, `dead path survived ${result.elapsed}ms`);
    const recovered = await request(port, 5000);
    assert.equal(recovered.response, 'request');
    assert.equal(attempts, 2);
    t.diagnostic(`dead connection closed in ${Math.round(result.elapsed)}ms; fresh connection succeeded`);
  });
