// HTTP proxy bytes in, certificate-verified TLS to one fixed broker out.
// No HTTP parsing, credential storage, destination routing or request retries.
'use strict';
const fs = require('node:fs');
const net = require('node:net');
const tls = require('node:tls');
const crypto = require('node:crypto');
const { spawn, fork } = require('node:child_process');

const [mode, raw] = process.argv.slice(2);
const config = raw ? JSON.parse(raw) : {};
// Production uses the UID-owned path; integration tests supply an isolated
// control directory so concurrent suites never share a supervisor.
const directory = config.controlDirectory || `/tmp/managoat-broker-relay-${process.getuid()}`;
const controlPath = `${directory}/control.sock`;
const fingerprint = crypto.createHash('sha256')
  .update(fs.readFileSync(__filename)).update(JSON.stringify(config)).digest('hex');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

// Phase clocks for the `ensure` path (#2906), parsed by
// Fountain.Broker.SetupTiming. Monotonic, and sandbox-side: the host span
// around this exec shares no clock with it, and the difference between the
// two is the provider round trip. Fixed numeric fields only — never an
// error, argument, URL, header or payload.
const since = start => Number((process.hrtime.bigint() - start) / 1000000n);
const report = (name, value) => {
  if (mode === 'ensure') process.stdout.write(`__MANAGOAT_BROKER__ ${name} ${value}\n`);
};

function secureDirectory() {
  try { fs.mkdirSync(directory, { mode: 0o700 }); } catch (e) {
    if (e.code !== 'EEXIST') throw e;
  }
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077)) {
    throw new Error('unsafe control directory');
  }
}

function control(command) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(controlPath);
    let data = '';
    socket.setTimeout(1000, () => socket.destroy(new Error('control timeout')));
    socket.on('connect', () => socket.end(command));
    socket.on('data', chunk => { data += chunk; });
    socket.on('end', () => {
      try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
    });
    socket.on('error', reject);
  });
}

async function status() {
  try { return await control('status'); } catch (e) {
    if (['ENOENT', 'ECONNREFUSED'].includes(e.code)) return null;
    throw e;
  }
}

async function stop() {
  if (!await status()) return;
  await control('stop');
  for (let i = 0; i < 100; i++) {
    if (!await status()) return;
    await delay(50);
  }
  throw new Error('stop timeout');
}

async function ensure() {
  const started = process.hrtime.bigint();
  try {
    await establish();
  } finally {
    // Reported on every path, so a failed ensure still accounts for the host
    // span it sat inside.
    report('relay_total', since(started));
  }
}

async function establish() {
  const probe = process.hrtime.bigint();
  const current = await status();
  report('relay_probe', since(probe));
  if (current && current.owner !== config.owner) throw new Error('owner mismatch');
  const replacing = Boolean(current && current.fingerprint !== fingerprint);
  if (replacing) await stop();
  report('relay_restart', replacing ? 1 : 0);
  const cold = !await status();
  if (cold) {
    // The caller serializes ensure/stop with flock. A stale socket has no
    // listener; only the successful supervisor removes it on shutdown.
    const spawning = process.hrtime.bigint();
    try { fs.unlinkSync(controlPath); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    const child = spawn(process.execPath, [__filename, 'supervise', raw], {
      detached: true, stdio: 'ignore', env: {}
    });
    child.unref();
    report('relay_spawn', since(spawning));
  }
  report('relay_warm', cold ? 0 : 1);
  const waiting = process.hrtime.bigint();
  let observed = false;
  for (let i = 0; i < 400; i++) {
    const running = await status();
    if (running && running.fingerprint === fingerprint && running.ready) {
      // How many 50 ms polls the fixed readiness schedule actually cost, so
      // whether a shorter first interval is worth anything is a measurement.
      report('relay_polls', i + 1);
      report('relay_ready', since(waiting));
      return;
    }
    if (observed && !running) throw new Error('supervisor stopped');
    observed = observed || Boolean(running);
    await delay(50);
  }
  throw new Error('readiness timeout');
}

function supervise() {
  let child, ready = false, stopping = false, ownsSocket = false;
  let failures = [];
  const server = net.createServer({ allowHalfOpen: true }, socket => {
    let request = '';
    socket.setTimeout(1000, () => socket.destroy());
    socket.on('error', () => {});
    socket.on('data', data => {
      request += data;
      if (request.length > 32) socket.destroy();
    });
    socket.on('end', () => {
      socket.end(JSON.stringify({
        owner: config.owner, fingerprint, ready, pid: process.pid, workerPid: child && child.pid
      }));
      if (request === 'stop') shutdown();
    });
  });
  function shutdown() {
    if (stopping) return;
    stopping = true;
    ready = false;
    // Keep status reachable until the worker has exited. Closing it here
    // makes stop() return while the old listener still owns the TCP port,
    // and finish() can then unlink a replacement supervisor's socket.
    if (child) child.kill('SIGTERM');
    else finish();
    setTimeout(() => { if (child) child.kill('SIGKILL'); }, 1000).unref();
  }
  function finish() {
    server.close();
    if (ownsSocket) {
      try { fs.unlinkSync(controlPath); } catch (_) { /* already removed */ }
    }
    process.exit(0);
  }
  function startWorker() {
    child = fork(__filename, ['worker', raw], { silent: true, env: {} });
    child.stdout.resume();
    child.stderr.resume();
    child.on('message', message => { if (message === 'ready') ready = true; });
    child.on('error', shutdown);
    child.on('exit', () => {
      child = null;
      ready = false;
      if (stopping) return finish();
      failures = failures.filter(at => Date.now() - at < 60_000);
      failures.push(Date.now());
      if (failures.length >= 3) return shutdown();
      setTimeout(startWorker, 250);
    });
  }
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
  server.on('error', () => process.exit(1));
  server.listen(controlPath, () => { ownsSocket = true; startWorker(); });
}

function upstream() {
  const socket = tls.connect({
    host: config.host, port: config.port,
    servername: net.isIP(config.host) ? undefined : config.host,
    ca: fs.readFileSync(config.ca), rejectUnauthorized: true,
    minVersion: 'TLSv1.2', allowHalfOpen: true
  });
  // Bound connection establishment, never a legitimate long-lived stream.
  socket.setTimeout(10_000, () => socket.destroy(new Error('TLS setup timeout')));
  socket.once('secureConnect', () => socket.setTimeout(0));
  return socket;
}

async function worker() {
  // Readiness includes a real, verified upstream handshake, without a token.
  await new Promise((resolve, reject) => {
    const probe = upstream();
    probe.once('error', reject);
    probe.once('secureConnect', () => { probe.destroy(); resolve(); });
  });
  const sockets = new Set();
  const server = net.createServer({ allowHalfOpen: true }, client => {
    client.pause();
    const remote = upstream();
    sockets.add(client);
    sockets.add(remote);
    const close = () => { client.destroy(); remote.destroy(); };
    client.on('error', close);
    remote.on('error', close);
    client.on('close', () => { sockets.delete(client); remote.destroy(); });
    remote.on('close', () => {
      sockets.delete(remote);
      // A clean upstream EOF has already piped end() to the client. Let its
      // buffered response drain; destroy() here truncates slow downloads.
      if (!remote.readableEnded) client.destroy();
    });
    remote.once('secureConnect', () => {
      client.pipe(remote);
      remote.pipe(client);
    });
  });
  server.maxConnections = 256;
  server.on('error', () => process.exit(1));
  server.listen(config.listen, '127.0.0.1', () => process.send('ready'));
  process.on('SIGTERM', () => {
    for (const socket of sockets) socket.destroy();
    server.close(() => process.exit(0));
  });
  // A supervisor disappearing must not leave an orphan listener.
  process.on('disconnect', () => process.exit(1));
}

async function main() {
  secureDirectory();
  if (mode === 'ensure') await ensure();
  else if (mode === 'stop') await stop();
  else if (mode === 'supervise') supervise();
  else if (mode === 'worker') await worker();
  else throw new Error('unknown mode');
}

main().catch(() => {
  // Never print raw errors, arguments, URLs, headers or payloads.
  process.stderr.write('broker transport relay unavailable\n');
  process.exit(1);
});
