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

microk8s enable "argocd"
