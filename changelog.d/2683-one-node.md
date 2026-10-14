### Upgrade notes

- **Fountain runs as one node** (#2683, ADR 0072). Before you take this
  release, run one replica and deploy with the Recreate strategy, which stops
  the old pod before it starts the new one. The Kubernetes baseline in
  `deploy/k8s/` now does both and no longer ships a PodDisruptionBudget. On
  Fly, run one machine (`fly deploy --ha=false`, or `fly scale count 1`). A
  rolling deploy of this release would briefly run two nodes that no longer
  cluster. Every deploy now has a short gap, about 30 s, in which the API does
  not answer; conversations come back when the new node boots. See
  [Fountain runs as one node](https://managoat.com/docs/guides/operate/upgrade#fountain-runs-as-one-node).

### Removed

- Erlang clustering (#2683). `CLUSTER_DNS_QUERY` is no longer read, the
  release no longer names Fly nodes after their private address, and
  `RELEASE_COOKIE` no longer turns anything on. Running more than one replica
  is unsupported.
