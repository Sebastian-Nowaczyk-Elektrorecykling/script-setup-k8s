#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
require_microk8s

if k get storageclass longhorn >/dev/null 2>&1; then
  log "longhorn already installed"
else
  microk8s helm repo add longhorn https://charts.longhorn.io
  microk8s helm repo update
  microk8s helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace
fi

if k get storageclass microk8s-hostpath >/dev/null 2>&1; then
  k annotate storageclass microk8s-hostpath storageclass.kubernetes.io/is-default-class=false --overwrite || true
  k annotate storageclass microk8s-hostpath storageclass.beta.kubernetes.io/is-default-class=false --overwrite || true
fi
k annotate storageclass longhorn storageclass.kubernetes.io/is-default-class=true --overwrite
k annotate storageclass longhorn storageclass.beta.kubernetes.io/is-default-class=true --overwrite
assert_default_storage

k apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.0.yaml
