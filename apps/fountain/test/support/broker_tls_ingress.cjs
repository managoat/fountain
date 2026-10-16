// Test-only TLS ingress in front of the real Managoat broker listener.
'use strict';
const tls = require('node:tls');
const net = require('node:net');
const fs = require('node:fs');
const [port, cert, key] = process.argv.slice(2);
const sockets = new Set();
const server = tls.createServer({ cert: fs.readFileSync(cert), key: fs.readFileSync(key) }, client => {
  const upstream = net.connect(Number(port), '127.0.0.1');
  for (const socket of [client, upstream]) {
    sockets.add(socket);
    socket.on('error', () => { client.destroy(); upstream.destroy(); });
    socket.on('close', () => { sockets.delete(socket); client.destroy(); upstream.destroy(); });
  }
  client.pipe(upstream).pipe(client);
});
server.on('tlsClientError', () => {});
server.listen(0, '127.0.0.1', () => process.stdout.write(`${server.address().port}\n`));
process.stdin.resume();
process.stdin.on('end', () => {
  for (const socket of sockets) socket.destroy();
  server.close();
});
