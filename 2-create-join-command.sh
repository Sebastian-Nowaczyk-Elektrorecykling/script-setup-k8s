#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
require_microk8s
ROLE="${1:-worker}"
case "$ROLE" in controller|worker|hybrid) ;; *) die "Usage: $0 controller|worker|hybrid" ;; esac
output="$(microk8s add-node --format short)"
join_cmd="$(grep -m1 '^microk8s join ' <<<"$output")"
[[ -n "$join_cmd" ]] || die "Could not extract a join command"
[[ "$ROLE" == worker ]] && join_cmd+=" --worker"
printf '%s\n' "$join_cmd"
printf '# On the new host: ./12-join-node.sh %s <host:25000/token/hash>\n' "$ROLE"
