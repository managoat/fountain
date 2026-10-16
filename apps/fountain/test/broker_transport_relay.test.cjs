'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const tls = require('node:tls');
const crypto = require('node:crypto');
const { execFile, execFileSync } = require('node:child_process');
const { promisify } = require('node:util');
const exec = promisify(execFile);
const relay = path.resolve(__dirname, '../priv/broker/transport-relay.cjs');
const controlPath = `/tmp/managoat-broker-relay-${process.getuid()}/control.sock`;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function command(mode, config) {
  return exec('flock', ['-w', '30', '/tmp/fountain-broker-transport-relay.lock',
    process.execPath, relay, mode, JSON.stringify(config)], { timeout: 30_000 });
}

async function status() {
  return new Promise((resolve, reject) => {
    const socket = net.connect(controlPath, () => socket.end('status'));
    let data = '';
    socket.on('data', chunk => { data += chunk; });
    socket.on('end', () => resolve(JSON.parse(data)));
    socket.on('error', reject);
  });
}

async function until(check) {
  for (let i = 0; i < 100; i++) {
    if (await check()) return;
    await delay(50);
  }
  assert.fail('condition did not become true');
}

async function exchange(port, bytes) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1', () => socket.write(bytes));
    const chunks = [];
    let length = 0;
    socket.setTimeout(5000, () => socket.destroy(new Error('exchange timeout')));
    socket.on('data', data => {
      chunks.push(data);
      length += data.length;
      if (length === bytes.length) { socket.destroy(); resolve(Buffer.concat(chunks)); }
    });
    socket.on('error', reject);
    socket.on('end', () => { if (length !== bytes.length) reject(new Error('short exchange')); });
  });
}

test('transport relay integration', { timeout: 60_000 }, async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-test-'));
  const cert = path.join(directory, 'cert.pem');
  const key = path.join(directory, 'key.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost'], { stdio: 'ignore' });
  const peers = new Set();
  const server = tls.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert) }, s => {
    peers.add(s);
    s.on('error', () => {});
    s.on('close', () => peers.delete(s));
    s.pipe(s);
  });
  server.on('tlsClientError', () => {});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const portReservation = net.createServer();
  await new Promise(resolve => portReservation.listen(0, '127.0.0.1', resolve));
  const listen = portReservation.address().port;
  await new Promise(resolve => portReservation.close(resolve));
  const config = { host: 'localhost', port: server.address().port, listen,
    owner: 'conversation-test', ca: cert };
  t.after(async () => {
    await command('stop', config);
    for (const peer of peers) peer.destroy();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(directory, { recursive: true });
  });

  await t.test('ready only after verified TLS; idempotent ensure preserves the worker', async () => {
    await command('ensure', config);
    const before = await status();
    assert.equal(before.ready, true);
    await command('ensure', config);
    assert.equal((await status()).pid, before.pid);
    await assert.rejects(command('ensure', { ...config, owner: 'another-conversation' }));
    assert.equal((await status()).pid, before.pid);
  });

  await t.test('CONNECT and absolute-form HTTP bytes, including rotated tokens, are unchanged', async () => {
    for (const token of ['old-session', 'new-session']) {
      for (const request of ['CONNECT example.org:443 HTTP/1.1', 'GET http://example.org/x HTTP/1.1']) {
        const bytes = Buffer.from(`${request}\r\nProxy-Authorization: Basic ${token}\r\n\r\n`);
        assert.deepEqual(await exchange(listen, bytes), bytes);
      }
    }
  });

  await t.test('streams a large binary payload with backpressure', async () => {
    const bytes = crypto.randomBytes(8 * 1024 * 1024);
    assert.deepEqual(await exchange(listen, bytes), bytes);
  });

  await t.test('client half-close and slow response drain preserve every byte', async () => {
    const payload = crypto.randomBytes(4 * 1024 * 1024);
    const responsePeers = new Set();
    const responseServer = tls.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert),
      allowHalfOpen: true }, socket => {
      responsePeers.add(socket);
      socket.on('close', () => responsePeers.delete(socket));
      socket.on('error', () => {});
      socket.on('data', () => {});
      socket.on('end', () => socket.end(payload));
    });
    // A readiness probe can disconnect before secureConnection is emitted.
    // Track raw sockets too so the test origin's close cannot wait on one.
    responseServer.on('connection', socket => {
      responsePeers.add(socket);
      socket.on('close', () => responsePeers.delete(socket));
    });
    await new Promise(resolve => responseServer.listen(0, '127.0.0.1', resolve));
    try {
      await command('ensure', { ...config, port: responseServer.address().port });
      const received = await new Promise((resolve, reject) => {
        const socket = net.connect(listen, '127.0.0.1', () => socket.end('request'));
        const chunks = [];
        socket.on('data', chunk => {
          chunks.push(chunk);
          socket.pause();
          setTimeout(() => socket.resume(), 2);
        });
        socket.on('end', () => resolve(Buffer.concat(chunks)));
        socket.on('error', reject);
        socket.setTimeout(5000, () => socket.destroy(new Error('slow response timeout')));
      });
      assert.deepEqual(received, payload);
    } finally {
      await command('ensure', config);
      for (const socket of responsePeers) socket.destroy();
      await new Promise(resolve => responseServer.close(resolve));
    }
  });

  await t.test('worker failure is supervised and subsequent connections recover', async () => {
    const before = await status();
    process.kill(before.workerPid, 'SIGKILL');
    await until(async () => {
      const next = await status();
      return next.ready && next.workerPid !== before.workerPid;
    });
    assert.deepEqual(await exchange(listen, Buffer.from('after restart')), Buffer.from('after restart'));
  });

  await t.test('stop closes the listener; wake starts a new ready worker', async () => {
    await command('stop', config);
    await assert.rejects(exchange(listen, Buffer.from('stopped')));
    await command('ensure', config);
    assert.deepEqual(await exchange(listen, Buffer.from('awake')), Buffer.from('awake'));
  });

  await t.test('supervisor loss closes the worker; ensure repairs the stale socket', async () => {
    const before = await status();
    process.kill(before.pid, 'SIGKILL');
    await until(async () => {
      try { await exchange(listen, Buffer.from('probe')); return false; }
      catch (_) { return true; }
    });
    await command('ensure', config);
    assert.notEqual((await status()).pid, before.pid);
    assert.deepEqual(await exchange(listen, Buffer.from('repaired')), Buffer.from('repaired'));
  });

  await t.test('hostname mismatch fails closed, even with a trusted certificate', async () => {
    await command('stop', config);
    await assert.rejects(command('ensure', { ...config, host: '127.0.0.1' }));
    await assert.rejects(exchange(listen, Buffer.from('must not forward')));
  });

  await t.test('untrusted certificate fails closed', async () => {
    await assert.rejects(command('ensure', { ...config, ca: '/etc/ssl/certs/ca-certificates.crt' }));
    await assert.rejects(exchange(listen, Buffer.from('must not forward')));
  });
});
