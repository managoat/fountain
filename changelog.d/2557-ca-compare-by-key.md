### Fixed

- **A wake no longer rebuilds the sandbox's trust store** (#2557). The broker
  CA is derived from a fixed seed, but its signature is randomised, so every
  copy Fountain wrote differed from the one already installed byte for byte.
  The install therefore rebuilt the whole system trust store on every wake,
  about 1.5–2.3 s. It now compares the certificates' public keys, which is how
  TLS clients match a trust anchor, and skips the rebuild when they agree.
