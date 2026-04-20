#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="${NAMESPACE:-observability}"
CHECKOUT_PORT="${CHECKOUT_PORT:-18000}"
VM_PORT="${VM_PORT:-18428}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local attempts="${3:-30}"

  for _ in $(seq 1 "$attempts"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "ready: $name"
      return 0
    fi
    sleep 2
  done

  echo "timed out waiting for $name at $url" >&2
  return 1
}

need_cmd kubectl
need_cmd curl
need_cmd python3

kubectl -n "$NAMESPACE" rollout status deployment/otel-collector --timeout=180s >/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/inventory-api --timeout=180s >/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/checkout-api --timeout=180s >/dev/null

kubectl -n "$NAMESPACE" port-forward svc/checkout-api "${CHECKOUT_PORT}:8000" >/tmp/victoria-checkout-pf.log 2>&1 &
CHECKOUT_PF_PID=$!
kubectl -n "$NAMESPACE" port-forward svc/victoria-metrics "${VM_PORT}:8428" >/tmp/victoria-metrics-pf.log 2>&1 &
VM_PF_PID=$!

cleanup() {
  kill "$CHECKOUT_PF_PID" "$VM_PF_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_url "checkout-api" "http://127.0.0.1:${CHECKOUT_PORT}/healthz"
wait_for_url "victoria-metrics" "http://127.0.0.1:${VM_PORT}/health"

REQUEST_BODY='{"user_id":"demo-user","sku":"sku-1","quantity":1,"mode":"ok"}'
CHECKOUT_RESPONSE="$(curl -fsS -X POST "http://127.0.0.1:${CHECKOUT_PORT}/api/checkout" -H 'Content-Type: application/json' -d "$REQUEST_BODY")"
TRACE_ID="$(RESPONSE="$CHECKOUT_RESPONSE" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["RESPONSE"])
print(payload["trace_id"])
PY
)"

echo "trace_id=$TRACE_ID"

for _ in $(seq 1 30); do
  RESPONSE="$(curl -fsS --get "http://127.0.0.1:${VM_PORT}/api/v1/query" --data-urlencode 'query=sum(demo_checkout_requests_total)' || true)"
  if PROM_JSON="$RESPONSE" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ["PROM_JSON"])
except json.JSONDecodeError:
    sys.exit(1)

result = payload.get("data", {}).get("result", [])
sys.exit(0 if result else 1)
PY
  then
    echo "ready: victoria-metrics query"
    echo "smoke test passed"
    exit 0
  fi
  sleep 2
done

echo "timed out waiting for checkout metrics in VictoriaMetrics" >&2
exit 1
