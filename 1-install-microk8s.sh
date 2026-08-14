#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
require_cmd snap

ROLE="${1:-hybrid}"
case "$ROLE" in controller|worker|hybrid) ;; *) die "Usage: $0 controller|worker|hybrid" ;; esac
TARGET_USER="seba"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || die "Could not determine home directory for $TARGET_USER"

sudo ln -s /var/lib/snapd/snap /snap

if snap list microk8s >/dev/null 2>&1; then
  sudo snap refresh microk8s
else
  sudo snap install microk8s --classic
fi
sudo usermod -a -G microk8s "$TARGET_USER"
sudo install -d -m 0770 -o "$TARGET_USER" -g microk8s "$TARGET_HOME/.kube"

sudo ln -s /var/lib/snapd/snap/bin/microk8s /bin

sudo microk8s status --wait-ready --timeout 600
sudo microk8s config > "$TARGET_HOME/.kube/config"
sudo chown "$TARGET_USER:microk8s" "$TARGET_HOME/.kube/config"
sudo chmod 600 "$TARGET_HOME/.kube/config"

NODE_NAME="$(hostname -s | tr '[:upper:]_' '[:lower:]-')"
sudo microk8s kubectl label node "$NODE_NAME" "platform.microk8s.io/role=$ROLE" "node.kubernetes.io/instance-type=bare-metal" --overwrite || true
case "$ROLE" in
  controller)
    sudo microk8s kubectl label node "$NODE_NAME" node-role.kubernetes.io/control-plane= --overwrite
    sudo microk8s kubectl taint node "$NODE_NAME" node-role.kubernetes.io/control-plane=:NoSchedule --overwrite
    ;;
  worker)
    sudo microk8s kubectl label node "$NODE_NAME" node-role.kubernetes.io/worker= --overwrite
    ;;
  hybrid)
    sudo microk8s kubectl label node "$NODE_NAME" node-role.kubernetes.io/control-plane= node-role.kubernetes.io/worker= --overwrite
    sudo microk8s kubectl taint node "$NODE_NAME" node-role.kubernetes.io/control-plane- || true
    ;;
esac
log "run: newgrp microk8s"
log "MicroK8s is ready. Re-login before running non-sudo microk8s commands if group membership was new."
