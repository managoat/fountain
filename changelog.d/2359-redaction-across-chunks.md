### Security

- **Secret redaction now holds when output splits a value across chunks**
  (#2359). Before this fix, redaction checked each stored output chunk
  separately. A registered secret split between two chunks matched neither
  chunk, so both halves were stored and streamed as plain text. This happened
  in a model's streamed reply and in raw stdout or stderr. A turn's stored
  reply text, which the search API returns, then held the whole value. Output
  whose end could be the start of a secret is now held until the next chunk
  arrives. Other output is written without delay.
- A secret containing a quote, a backslash or a newline, such as a PEM key, is
  now redacted in agent protocol output (#2359). That output is stored as
  JSON, so these characters are escaped, and redaction did not recognise the
  escaped form.
