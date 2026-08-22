#!/usr/bin/env bash
# Prepares a freshly flashed Raspberry Pi (Raspberry Pi OS 64-bit, SSH already enabled) for
# K3s and installs K3s itself - see docs/SCALING.md, section "Real 2-node hardware
# setup". Idempotent: can be run multiple times (e.g. re-run after the reboot required for
# cgroups), it detects and skips steps already done.
#
# Usage (run on the Pi over SSH, NOT from the laptop):
#   ./setup-node.sh server                             # for the FIRST Pi (spare Pi, becomes the K3s server)
#   K3S_TOKEN=<TOKEN> ./setup-node.sh agent <URL>       # for the SECOND Pi (joins the server) - RECOMMENDED
#   ./setup-node.sh agent <URL> <TOKEN>                 # also works, but the token then ends up in
#                                                        # ~/.bash_history and is visible via "ps aux"
# <URL>   = https://<server-pi-ip>:6443
# <TOKEN> = output of "sudo cat /var/lib/rancher/k3s/server/node-token" on the server Pi
#
# Registry credentials (for /etc/rancher/k3s/registries.yaml) are prompted interactively,
# or set them beforehand via environment variable: REGISTRY_USER=... REGISTRY_PASSWORD=... ./setup-node.sh server

set -euo pipefail

ROLE="${1:-}"
if [[ "$ROLE" != "server" && "$ROLE" != "agent" ]]; then
  echo "Usage: $0 server" >&2
  echo "       K3S_TOKEN=<TOKEN> $0 agent <K3S_URL>   (recommended)" >&2
  echo "       $0 agent <K3S_URL> <K3S_TOKEN>          (token then visible in shell history/ps)" >&2
  exit 1
fi

if [[ "$ROLE" == "agent" ]]; then
  K3S_URL="${2:-${K3S_URL:-}}"
  K3S_TOKEN="${3:-${K3S_TOKEN:-}}"
  if [[ -z "$K3S_URL" || -z "$K3S_TOKEN" ]]; then
    echo "For role 'agent', K3S_URL and K3S_TOKEN must be passed as arguments or set as environment variables." >&2
    exit 1
  fi
  if [[ -n "${3:-}" ]]; then
    echo "Note: passing the token on the command line makes it visible in shell history - prefer setting K3S_TOKEN as an env var." >&2
  fi
fi

if [[ $EUID -eq 0 ]]; then
  echo "Please do NOT run as root - the script calls 'sudo' itself where needed." >&2
  exit 1
fi

echo "=== [1/5] Updating package list + upgrading ==="
sudo apt-get update -qq
sudo apt-get dist-upgrade -y -qq

echo "=== [2/5] Checking cgroups (memory+cpu, required for K3s) ==="
# On Raspberry Pi OS Bookworm (and modern Debian systems in general) cgroup v2 runs in
# "unified" mode - /proc/cgroups is the legacy v1 view and often does NOT list the memory
# controller at all, even though it has long been available via the v2 hierarchy (which
# containerd/K3s actually uses). /sys/fs/cgroup/cgroup.controllers is authoritative; /proc/cgroups
# is only a fallback for genuine legacy systems without v2.
if [[ -f /sys/fs/cgroup/cgroup.controllers ]] && grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
  echo "cgroups (v2, unified) already active - continuing."
elif [[ ! -f /sys/fs/cgroup/cgroup.controllers ]] && grep -qE '^\s*memory\s+\S+\s+\S+\s+1\s*$' /proc/cgroups; then
  echo "cgroups (v1) already active - continuing."
else
  CMDLINE_FILE=""
  for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    if [[ -f "$candidate" ]]; then
      CMDLINE_FILE="$candidate"
      break
    fi
  done
  if [[ -z "$CMDLINE_FILE" ]]; then
    echo "cmdline.txt not found (neither /boot/firmware/ nor /boot/) - check manually." >&2
    exit 1
  fi
  if grep -q "cgroup_enable=memory" "$CMDLINE_FILE"; then
    echo "cgroup flags are already in $CMDLINE_FILE, but not active yet - reboot required."
  else
    echo "Adding cgroup flags to $CMDLINE_FILE..."
    sudo sed -i 's/$/ cgroup_memory=1 cgroup_enable=memory/' "$CMDLINE_FILE"
  fi
  echo
  echo ">>> Reboot required before K3s can be installed. <<<"
  read -r -p "Reboot now? [y/N] " ANSWER
  if [[ "$ANSWER" =~ ^[yY]$ ]]; then
    echo "After the reboot, just run this script again with the same arguments."
    sudo reboot
  else
    echo "Please reboot manually and then run this script again. Aborting."
  fi
  exit 0
fi

echo "=== [3/5] Setting up registry access (/etc/rancher/k3s/registries.yaml) ==="
REGISTRY_HOST="registry.example.com"
if [[ -f /etc/rancher/k3s/registries.yaml ]]; then
  echo "/etc/rancher/k3s/registries.yaml already exists - skipping (delete it to be asked again)."
else
  if [[ -z "${REGISTRY_USER:-}" ]]; then
    read -r -p "Registry username for ${REGISTRY_HOST}: " REGISTRY_USER
  fi
  if [[ -z "${REGISTRY_PASSWORD:-}" ]]; then
    read -r -s -p "Registry password for ${REGISTRY_HOST}: " REGISTRY_PASSWORD
    echo
  fi
  sudo mkdir -p /etc/rancher/k3s
  sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<EOF
mirrors:
  "${REGISTRY_HOST}":
    endpoint:
      - "https://${REGISTRY_HOST}"
configs:
  "${REGISTRY_HOST}":
    auth:
      username: "${REGISTRY_USER}"
      password: "${REGISTRY_PASSWORD}"
EOF
  sudo chmod 600 /etc/rancher/k3s/registries.yaml
  echo "registries.yaml written."
fi

echo "=== [4/5] Installing K3s (role: $ROLE) ==="
if systemctl is-active --quiet k3s 2>/dev/null || systemctl is-active --quiet k3s-agent 2>/dev/null; then
  echo "K3s is already running here - skipping installation. To reinstall, first run"
  echo "'sudo /usr/local/bin/k3s-uninstall.sh' or 'k3s-agent-uninstall.sh'."
else
  if [[ "$ROLE" == "server" ]]; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --write-kubeconfig-mode 644" sh -
  else
    curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -
  fi
fi

echo "=== [5/5] Status ==="
# On a Pi (especially SD-card I/O), API server/containerd/Flannel take noticeably longer on
# the very first start than on typical server hardware - a single immediate check here would
# often incorrectly show "No resources found" even though K3s is simply still starting up.
wait_for_node() {
  for _ in $(seq 1 24); do
    if sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 5
  done
  return 1
}
if [[ "$ROLE" == "server" ]]; then
  if ! wait_for_node; then
    echo "Node still not visible after 2 minutes - check status/logs:"
    echo "  sudo systemctl status k3s --no-pager"
    echo "  sudo journalctl -u k3s -n 50 --no-pager"
  fi
  sudo k3s kubectl get nodes
  echo
  echo "Node token (for the second Pi, role 'agent'):"
  sudo cat /var/lib/rancher/k3s/server/node-token
  echo
  echo "Fetch the kubeconfig onto your laptop:"
  echo "  scp $(whoami)@$(hostname -I | awk '{print $1}'):/etc/rancher/k3s/k3s.yaml ~/.kube/studylife-config"
  echo "  sed -i 's/127.0.0.1/$(hostname -I | awk '{print $1}')/' ~/.kube/studylife-config"
  echo "  export KUBECONFIG=~/.kube/studylife-config"
else
  echo "(run kubectl on the server Pi to check that it joined - may take 1-2 minutes)"
fi

echo
echo "Done."
