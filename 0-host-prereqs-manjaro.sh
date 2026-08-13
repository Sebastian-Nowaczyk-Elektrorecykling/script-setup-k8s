#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
require_root
require_cmd pacman

section "Install Manjaro packages"
pacman -Sy --needed --noconfirm \
  open-iscsi nfs-utils cryptsetup device-mapper \
  iproute2 iptables-nft nftables socat conntrack-tools ethtool ebtables \
  curl jq git rsync gettext openssl ca-certificates tar gzip unzip python \
  pciutils qemu-base dnsmasq pciutils

section "Load kernel modules"
cat > /etc/modules-load.d/microk8s-platform.conf <<'MODULES'
overlay
br_netfilter
iscsi_tcp
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
kvm
vhost_net
tun
MODULES
for module in overlay br_netfilter iscsi_tcp ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack kvm vhost_net tun; do
  modprobe "$module" 2>/dev/null || warn "Could not load optional module $module"
done
if grep -qi GenuineIntel /proc/cpuinfo; then modprobe kvm_intel 2>/dev/null || true; fi
if grep -qi AuthenticAMD /proc/cpuinfo; then modprobe kvm_amd 2>/dev/null || true; fi

section "Apply sysctls"
cat > /etc/sysctl.d/99-microk8s-platform.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
vm.max_map_count = 262144
SYSCTL
sysctl --system >/dev/null

section "Enable storage prerequisites"
if ! systemctl enable --now iscsid.service; then
  systemctl enable --now iscsid.socket || die "Unable to start iscsid"
fi
systemctl enable --now rpcbind.service || true
if systemctl is-active --quiet multipathd.service 2>/dev/null; then
  warn "multipathd is active. Exclude Longhorn devices from multipath or disable multipathd on dedicated cluster nodes."
fi


section "Check acceleration"
if [[ -c /dev/kvm ]]; then
  log "/dev/kvm is available"
else
  warn "/dev/kvm is absent. Enable virtualization in firmware or explicitly allow KubeVirt software emulation."
fi
if lspci | grep -Eqi 'NVIDIA|AMD/ATI|VGA compatible controller.*Intel|3D controller.*Intel|Display controller.*Intel'; then
  log "A GPU/display device was detected. Vendor-specific runtime validation happens after joining the cluster."
fi

if ! systemctl is-active --quiet snapd.service; then
  warn "snapd is not active even though snap is installed; enable snapd before installing MicroK8s."
fi

cat <<'MSG'
Host preparation completed.

The obsolete bridge-utils package is intentionally not used; iproute2 provides the modern bridge tooling Kubernetes needs.
A reboot is recommended after kernel, virtualization, or GPU-driver changes.
MSG
