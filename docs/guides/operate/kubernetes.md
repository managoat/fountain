# Deploy on Kubernetes

This guide shows you which manifests to apply, and which to read and not
apply.

## Use `deploy/k8s/`

A portable baseline lives in
[`deploy/k8s/`](https://github.com/managoat/fountain/tree/main/deploy/k8s).
They are plain manifests that you apply with `kubectl apply -k`. They assume
no operators and no CRDs.

You bring a Postgres, an ingress controller, and the `fountain-secrets`
Secret. Its README walks you through the rest. The manifests explain the
choices about probes and scale in inline comments.

## Track `main` with Flux

Every merge to `main` publishes `deploy/` as an OCI artifact at
`ghcr.io/managoat/fountain-manifests`, with the image tag built from
that commit in place of the release pin. The hosted instance runs from it. A
Flux `OCIRepository` on the tag `latest` and a `Kustomization` on the path
`./deploy/k8s` give you the same, and Flux `patches` hold your changes.

## Run more than one replica

The baseline runs one replica. With more, the pods must form an Erlang
cluster, or conversation streams break for the viewer on the other pod. Read
[Architecture](../../architecture.md#clustering) for why.

Add a headless Service that selects the fountain pods. Then set these
variables on the container.

```yaml
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: RELEASE_DISTRIBUTION
  value: name
# The basename must be `fountain_server`, the release name. libcluster
# derives the peer node name from it.
- name: RELEASE_NODE
  value: fountain_server@$(POD_IP)
# The same value on every pod. A missing cookie lets each pod generate its
# own, and the pods never connect.
- name: RELEASE_COOKIE
  valueFrom:
    secretKeyRef:
      name: fountain-secrets
      key: RELEASE_COOKIE
# Pin the distribution port, so a NetworkPolicy can name it.
- name: ERL_AFLAGS
  value: "-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100"
# The headless Service, as a FQDN.
- name: CLUSTER_DNS_QUERY
  value: fountain-headless.fountain.svc.cluster.local
```

`POD_IP` must come before `RELEASE_NODE`. Kubernetes substitutes only the
variables declared earlier. Also open ports 4369 and 9100 between the pods.

## Two things to decide

**Migrations.** Boot migrations are safe with several replicas. A Postgres
advisory lock serializes them. To run them as a Job of their own instead, read
[Run migrations in a Job](database.md#run-migrations-in-a-job).

**Backups.** `deploy/k8s/backup-cronjob.yaml` sits commented out of the
kustomization until you create its secret. Read
[Back up and restore](back-up-and-restore.md).

## Verify it worked

```bash
kubectl rollout status deployment/fountain -n fountain
kubectl exec -n fountain deploy/fountain -- curl -sS localhost:4000/health/ready
```

## If it did not work

Read
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md).
Most symptoms here that look like a Kubernetes fault are the probe layout at
work.

## Related

- [Configure observability](observability.md), for the PrometheusRule.
- [Back up and restore](back-up-and-restore.md).
- [Architecture](../../architecture.md), for the cluster picture.
