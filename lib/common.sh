#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$ROOT_DIR/.state"
RENDER_DIR="$ROOT_DIR/rendered"
SECRETS_FILE="$STATE_DIR/secrets.env"
LOCK_DIR="$STATE_DIR/locks"

mkdir -p "$STATE_DIR" "$RENDER_DIR" "$LOCK_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

export PATH="/snap/bin:$PATH"
export DOLLAR='$'

_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '%s [INFO] %s\n' "$(_ts)" "$*" >&2; }
warn() { printf '%s [WARN] %s\n' "$(_ts)" "$*" >&2; }
error() { printf '%s [ERROR] %s\n' "$(_ts)" "$*" >&2; }
die() { error "$*"; exit 1; }
section() { printf '\n===== %s =====\n' "$*" >&2; }

_on_error() {
  local status=$?
  error "Failure at ${BASH_SOURCE[1]}:${BASH_LINENO[0]} (exit $status): ${BASH_COMMAND}"
  exit "$status"
}
trap _on_error ERR

have_cmd() { command -v "$1" >/dev/null 2>&1; }
require_cmd() { have_cmd "$1" || die "Required command not found: $1"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root (sudo)."; }

bool_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

require_config() {
  [[ -f "$ROOT_DIR/.env" ]] || die "Missing .env. Run: cp .env.example .env, then edit it."
  [[ -n "${BASE_DOMAIN:-}" ]] || die "BASE_DOMAIN is required"
  [[ -n "${METALLB_RANGE:-}" ]] || die "METALLB_RANGE is required"
  [[ "$BASE_DOMAIN" != example.com ]] || die "Replace the example BASE_DOMAIN"
  case "${TLS_MODE:-selfsigned}" in
    selfsigned|external) ;;
    *) die "TLS_MODE must be selfsigned or external" ;;
  esac
}

require_microk8s() {
  have_cmd microk8s || die "microk8s is not installed or /snap/bin is not in PATH"
  microk8s status --wait-ready --timeout 600 >/dev/null
}

mk() { microk8s "$@"; }
k() { microk8s kubectl "$@"; }
h() { microk8s helm3 "$@"; }

random_hex() {
  local bytes="${1:-32}"
  if have_cmd openssl; then
    openssl rand -hex "$bytes"
  else
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

namespace() {
  local name="$1"
  k create namespace "$name" --dry-run=client -o yaml | k apply -f - >/dev/null
}

secret_literals() {
  local ns="$1" name="$2"
  shift 2
  local args=()
  while (( $# )); do
    args+=("--from-literal=$1")
    shift
  done
  namespace "$ns"
  k -n "$ns" create secret generic "$name" "${args[@]}" --dry-run=client -o yaml | k apply -f - >/dev/null
}

render() {
  local source="$1" destination="$2"
  require_cmd envsubst
  mkdir -p "$(dirname "$destination")"
  envsubst < "$source" > "$destination"
}

render_template() {
  local relative="$1" destination="${2:-$RENDER_DIR/${relative%.tmpl}}"
  local source="$ROOT_DIR/templates/$relative"
  [[ -f "$source" ]] || die "Template not found: $source"
  render "$source" "$destination"
  printf '%s\n' "$destination"
}

apply_template() {
  local relative="$1" destination="${2:-}"
  destination="$(render_template "$relative" "$destination")"
  k apply --server-side --force-conflicts -f "$destination"
}

apply_stdin() { k apply --server-side --force-conflicts -f -; }

helm_repo() {
  local name="$1" url="$2"
  h repo add "$name" "$url" --force-update >/dev/null
}

helm_upgrade() {
  local release="$1" chart="$2" ns="$3"
  shift 3
  namespace "$ns"
  h upgrade --install "$release" "$chart" --namespace "$ns" --create-namespace --wait --timeout 25m "$@"
}

wait_crd() {
  local crd="$1" timeout_seconds="${2:-600}" i
  for ((i=0; i<timeout_seconds; i+=2)); do
    k get crd "$crd" >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "Timed out waiting for CRD $crd"
}

wait_deployment() { k -n "$1" rollout status "deployment/$2" --timeout="${3:-20m}"; }
wait_statefulset() { k -n "$1" rollout status "statefulset/$2" --timeout="${3:-30m}"; }
wait_pods() { k -n "$1" wait pod -l "$2" --for=condition=Ready --timeout="${3:-20m}"; }

wait_cnpg() {
  local ns="$1" name="$2" timeout="${3:-30m}"
  k -n "$ns" wait "cluster/$name" --for=condition=Ready --timeout="$timeout"
}

wait_gateway_address() {
  local i address
  for ((i=0; i<180; i++)); do
    address="$(k -n platform-gateway get gateway platform -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
    if [[ -n "$address" ]]; then
      printf '%s\n' "$address"
      return 0
    fi
    sleep 5
  done
  die "Gateway did not receive an address from MetalLB"
}

wait_http() {
  local url="$1" attempts="${2:-120}" i
  for ((i=1; i<=attempts; i++)); do
    curl -kfsS --connect-timeout 3 --max-time 10 "$url" >/dev/null 2>&1 && return 0
    sleep 5
  done
  die "Timed out waiting for $url"
}

node_count() { k get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '; }
ready_node_count() { k get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ {c++} END {print c+0}'; }

recommended_replicas() {
  local requested="$1" nodes
  nodes="$(ready_node_count)"
  (( nodes < 1 )) && nodes=1
  (( requested > nodes )) && requested="$nodes"
  printf '%s\n' "$requested"
}

platform_host() { printf '%s.%s\n' "$1" "$BASE_DOMAIN"; }

acquire_lock() {
  local name="$1" lock="$LOCK_DIR/$name.lock"
  mkdir "$lock" 2>/dev/null || die "Another $name operation appears active: $lock"
  export ACTIVE_LOCK="$lock"
}
release_lock() { [[ -n "${ACTIVE_LOCK:-}" ]] && rmdir "$ACTIVE_LOCK" 2>/dev/null || true; }

write_checkpoint() { date --iso-8601=seconds > "$STATE_DIR/$1.done"; }
checkpoint_done() { [[ -f "$STATE_DIR/$1.done" ]]; }

sanitize_dns_label() {
  tr '[:upper:]_' '[:lower:]-' <<<"$1" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' | cut -c1-63
}


assert_default_storage() {
  local defaults
  defaults="$(k get storageclass -o json | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true" or .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"]=="true") | .metadata.name')"
  grep -qx longhorn <<<"$defaults" || die "Longhorn is not the only default StorageClass. Defaults: ${defaults//$'\n'/, }"
}
