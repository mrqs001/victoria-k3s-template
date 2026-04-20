#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "this script must run as root"
  echo "example:"
  echo "  sudo ./scripts/install-k3s.sh"
  exit 1
fi

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644" sh -

echo "k3s installed"
echo "kubeconfig: /etc/rancher/k3s/k3s.yaml"
echo "if kubectl is not on your PATH, k3s also installs one for local use"

