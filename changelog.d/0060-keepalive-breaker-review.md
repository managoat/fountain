### Changed

- **The ChatGPT keepalive's pause says so in the log, and holds better under
  a throttle that lasts** (#2476). When a replica pauses its keepalive jobs
  because `auth.openai.com` turned its address away for two accounts, it now
  logs one line at `error` starting `chatgpt refresh:`, with how many
  accounts and none of their ids, at most once a minute. A paused job whose
  subscription is known to be seven days unrenewed logs at `error` too
  (`chatgpt keepalive: grant … has gone N days unrenewed`), at most one line
  a minute per replica; until now the first `error` line was the 72-hour
  stop. The probe let through every fifteen minutes now keeps the pause
  going by itself when it is refused, for thirty minutes from the refusal,
  so a lasting throttle is one request per fifteen minutes for as long as a
  job is due to probe; before, the pause usually lapsed and two or three
  jobs called before it stood again. A job that was refused stays out of
  the probe's way for two hours, doubling with each refusal up to a day, so
  an account that is always refused cannot take every probe from the
  others. A probe that ended up making no request gives its turn to the
  next job. A 429, or a 403, whose body is labelled JSON and does not parse
  is counted as a throttled address like any other non-JSON body, where it
  used to be an ordinary failed attempt. Linking stays behind the
  `chatgpt_subscriptions` flag.

### Fixed

- **The deployment's ChatGPT grant no longer logs the raw reason when a
  renewal fails** (#2476). Since #1755 the two warnings starting `platform
  chatgpt:` printed the failure as Elixir inspects it. For a response whose
  JSON body was cut short in transit, that failure carried the body, so a
  truncated successful token response would have put part of a token in a
  warning line. No such response is known to have happened. The lines now
  say a status (`status 429`), `unreachable` or a short name, and a body
  that does not parse no longer reaches them.
