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
choices about probes and the deploy strategy in inline comments.

## Track `main` with Flux

Every merge to `main` publishes `deploy/` as an OCI artifact at
`ghcr.io/managoat/fountain-manifests`, with the image tag built from
that commit in place of the release pin. The maintainer's instance runs from it. A
Flux `OCIRepository` on the tag `latest` and a `Kustomization` on the path
`./deploy/k8s` give you the same, and Flux `patches` hold your changes.

## Run one replica

The baseline runs one replica with the `Recreate` deploy strategy. Keep both.
Fountain runs as one node, so more than one replica is not supported. Read
[Architecture](../../architecture.md#one-node) for why.

`Recreate` stops the old pod before it starts the new one, so two releases
never run at the same time. A deploy therefore has a short gap, about 30
seconds, in which the API answers nothing. The new pod's rehydrator then
starts a server again for each conversation that had one. Batch your merges
when you track `main`, because each one is a deploy.

## Two things to decide

**Migrations.** The pod migrates at boot, under a Postgres advisory lock. To
run them as a Job of their own instead, read
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
- [Architecture](../../architecture.md), for the system picture.
