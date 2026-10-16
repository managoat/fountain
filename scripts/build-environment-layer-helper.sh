#!/usr/bin/env bash
# Build the same Linux helpers included in the release image, for local use.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root/cli"
mkdir -p "$repo_root/apps/fountain/priv/environment_layers"
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -mod=readonly -trimpath \
    -o "$repo_root/apps/fountain/priv/environment_layers/managoat-layer-linux-$arch" ./cmd/managoat-layer
done
