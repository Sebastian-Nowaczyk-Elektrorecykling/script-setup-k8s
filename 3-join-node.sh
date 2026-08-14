#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
ROLE="${1:-worker}"
JOIN_ENDPOINT="${2:-}"
case "$ROLE" in controller|worker|hybrid) ;; *) die "Usage: $0 controller|worker|hybrid <host:25000/token/hash>" ;; esac
[[ -n "$JOIN_ENDPOINT" ]] || die "Usage: $0 controller|worker|hybrid <host:25000/token/hash>"

if ! snap list microk8s >/dev/null 2>&1; then
  sudo snap install microk8s --classic --channel="$MICROK8S_CHANNEL"
fi
sudo usermod -a -G microk8s "${SUDO_USER:-$USER}"
args=(join "$JOIN_ENDPOINT")
[[ "$ROLE" == worker ]] && args+=(--worker)
sudo microk8s "${args[@]}"
sudo "$SCRIPT_DIR/14-label-hardware.sh" || true
log "Node joined as $ROLE. From a controller run: ./13-label-node.sh $(hostname -s) $ROLE"
