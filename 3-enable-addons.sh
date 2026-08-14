#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
require_microk8s

section "Enable core MicroK8s add-ons"
for addon in dns rbac helm3 metrics-server cert-manager hostpath-storage; do
  microk8s enable "$addon"
done

section "Enable community add-on repository"
microk8s enable community


section "Enable CloudNativePG operator"
if ! k get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then
  if ! microk8s enable community:cloudnative-pg; then
    microk8s enable cloudnative-pg
  fi
fi
wait_crd clusters.postgresql.cnpg.io 900

# hostpath can remain for throwaway data, but it must not remain the default once Longhorn is installed.
if k get storageclass microk8s-hostpath >/dev/null 2>&1; then
  k annotate storageclass microk8s-hostpath storageclass.kubernetes.io/is-default-class=false --overwrite || true
  k annotate storageclass microk8s-hostpath storageclass.beta.kubernetes.io/is-default-class=false --overwrite || true
fi
