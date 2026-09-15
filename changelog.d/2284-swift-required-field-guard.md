### Fixed

- Swift SDK: generation now refuses a property that a server older than the
  change could not decode — one required here that the last release could leave
  out, or one that release published as `Optional` — unless it is pinned
  optional or recorded as a field no deployed server omits. Both baselines are
  read from the last release tag, so a change cannot regenerate the output and
  offer its own result as the baseline, and the decode side is read from that
  release's contract rather than its Swift models, since a shape the SDK did
  not expose is still one the server could return. The rule was written down but
  applied by hand, and the only thing catching a miss was whether some test
  happened to decode that type from a payload lacking the key; `Teammate`, the
  return of four public `TeamResource` methods, had no such test, so a required
  addition there would have broken every response from an older server whole
  with every gate green (#2284).
