### Security

- **HTTP/2 is no longer served** (#2700). Bandit's HTTP/2 stack is turned off
  to close EEF-CVE-2026-105659, where a trickle of WINDOW_UPDATE frames pins
  HTTP/2 stream processes indefinitely; no fixed Bandit release exists yet.
  Fountain answers HTTP/1.1 only, so a client that opens a cleartext h2c
  prior-knowledge connection to the port is disconnected. Browsers, the SDK,
  the CLI, WebSockets and SSE already use HTTP/1.1 to Fountain or to a TLS
  proxy in front of it; a proxy that speaks HTTP/2 to Fountain's port must
  be switched to HTTP/1.1.
