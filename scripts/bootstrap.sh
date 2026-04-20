#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="${NAMESPACE:-observability}"
HELM_IMAGE="${HELM_IMAGE:-alpine/helm:3.17.3}"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
APP_IMAGE="${APP_IMAGE:-ghcr.io/mrqs001/victoria-k3s-template-demo-app:main}"
GHCR_SECRET_NAME="${GHCR_SECRET_NAME:-ghcr-pull}"

if [[ ! -f "$KUBECONFIG_PATH" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

helm_cmd() {
  if command -v helm >/dev/null 2>&1; then
    helm "$@"
    return
  fi

  mkdir -p "$HOME/.config/helm" "$HOME/.cache/helm" "$HOME/.local/share/helm"
  docker run --rm \
    -v "$HOME/.config/helm:/root/.config/helm" \
    -v "$HOME/.cache/helm:/root/.cache/helm" \
    -v "$HOME/.local/share/helm:/root/.local/share/helm" \
    -v "$(dirname "$KUBECONFIG_PATH"):$(dirname "$KUBECONFIG_PATH"):ro" \
    -v "$ROOT_DIR:/work" \
    -w /work \
    -e KUBECONFIG="$KUBECONFIG_PATH" \
    --network host \
    "$HELM_IMAGE" "$@"
}

need_cmd kubectl
need_cmd docker

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

ensure_ghcr_pull_secret() {
  if [[ "$APP_IMAGE" != ghcr.io/* ]]; then
    return
  fi

  local registry="ghcr.io"
  local username="${GHCR_USERNAME:-}"
  local token="${GHCR_TOKEN:-}"

  if [[ -z "$username" || -z "$token" ]]; then
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      username="$(gh api user -q .login)"
      token="$(gh auth token)"
    else
      echo "APP_IMAGE points to ghcr.io but no GHCR credentials were found." >&2
      echo "Set GHCR_USERNAME and GHCR_TOKEN, or make the package public." >&2
      return
    fi
  fi

  kubectl -n "$NAMESPACE" delete secret "$GHCR_SECRET_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" create secret docker-registry "$GHCR_SECRET_NAME" \
    --docker-server="$registry" \
    --docker-username="$username" \
    --docker-password="$token" >/dev/null
  kubectl -n "$NAMESPACE" patch serviceaccount default --type merge \
    -p "{\"imagePullSecrets\":[{\"name\":\"$GHCR_SECRET_NAME\"}]}" >/dev/null
}

ensure_ghcr_pull_secret

helm_cmd repo add vm https://victoriametrics.github.io/helm-charts/
helm_cmd repo add grafana https://grafana.github.io/helm-charts
helm_cmd repo update

helm_cmd upgrade --install vms vm/victoria-metrics-single \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --wait \
  -f charts-values/victoria-metrics-single.yaml

helm_cmd upgrade --install vls vm/victoria-logs-single \
  --namespace "$NAMESPACE" \
  --wait \
  -f charts-values/victoria-logs-single.yaml

helm_cmd upgrade --install vts vm/victoria-traces-single \
  --namespace "$NAMESPACE" \
  --wait \
  -f charts-values/victoria-traces-single.yaml

helm_cmd upgrade --install grafana grafana/grafana \
  --namespace "$NAMESPACE" \
  --wait \
  -f charts-values/grafana.yaml

./scripts/kustomize-render.sh k8s/base | kubectl -n "$NAMESPACE" apply -f -

kubectl -n "$NAMESPACE" rollout status deployment/redis --timeout=180s
kubectl -n "$NAMESPACE" rollout status deployment/otel-collector --timeout=180s
kubectl -n "$NAMESPACE" rollout status deployment/inventory-api --timeout=180s
kubectl -n "$NAMESPACE" rollout status deployment/checkout-api --timeout=180s

echo "bootstrap complete"
echo "next:"
echo "  make port-forward-checkout"
echo "  make port-forward-grafana"
