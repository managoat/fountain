### Added

- **A Fly app can run more than one machine** (#2546). Set `RELEASE_COOKIE` as
  a secret and the release names each node after the machine's private IPv6
  address, runs Erlang distribution over IPv6, and finds its peers under
  `<app>.internal`; then `fly scale count 2`. Without the cookie a Fly
  machine runs alone, as before, and `CLUSTER_DNS_QUERY` set on Fly without
  it refuses to boot. Kubernetes is unchanged. Read
  [Run more than one machine](https://managoat.com/docs/guides/operate/fly#run-more-than-one-machine).

### Fixed

- **The image carries `bin/migrate` and `bin/server`** (#2546). The Dockerfile
  never copied `rel/`, so `mix release` built without its overlays and a
  migration Job pointed at `/app/bin/migrate` had nothing to run.
