#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="${NAMESPACE:-observability}"
CHECKOUT_PORT="${CHECKOUT_PORT:-18000}"
VM_PORT="${VM_PORT:-18428}"
VL_PORT="${VL_PORT:-19428}"
VT_PORT="${VT_PORT:-19429}"

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
kubectl -n "$NAMESPACE" port-forward svc/victoria-metrics-http "${VM_PORT}:8428" >/tmp/victoria-metrics-pf.log 2>&1 &
VM_PF_PID=$!
kubectl -n "$NAMESPACE" port-forward svc/victoria-logs-http "${VL_PORT}:9428" >/tmp/victoria-logs-pf.log 2>&1 &
VL_PF_PID=$!
kubectl -n "$NAMESPACE" port-forward svc/victoria-traces-http "${VT_PORT}:10428" >/tmp/victoria-traces-pf.log 2>&1 &
VT_PF_PID=$!

cleanup() {
  kill "$CHECKOUT_PF_PID" "$VM_PF_PID" "$VL_PF_PID" "$VT_PF_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_url "checkout-api" "http://127.0.0.1:${CHECKOUT_PORT}/healthz"
wait_for_url "victoria-metrics" "http://127.0.0.1:${VM_PORT}/health"
wait_for_url "victoria-logs" "http://127.0.0.1:${VL_PORT}/health"
wait_for_url "victoria-traces" "http://127.0.0.1:${VT_PORT}/health"

REQUEST_BODY='{"user_id":"demo-user","sku":"sku-1","quantity":1,"mode":"cache_cold"}'
CHECKOUT_RESPONSE="$(curl -fsS -X POST "http://127.0.0.1:${CHECKOUT_PORT}/api/checkout" -H 'Content-Type: application/json' -d "$REQUEST_BODY")"
TRACE_ID="$(RESPONSE="$CHECKOUT_RESPONSE" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["RESPONSE"])
print(payload["trace_id"])
PY
)"
ORDER_ID="$(RESPONSE="$CHECKOUT_RESPONSE" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["RESPONSE"])
print(payload["order_id"])
PY
)"

echo "trace_id=$TRACE_ID"
echo "order_id=$ORDER_ID"

for _ in $(seq 1 30); do
  RESPONSE="$(curl -fsS --get "http://127.0.0.1:${VM_PORT}/api/v1/query" --data-urlencode 'query=sum(demo_checkout_requests_total) + sum(demo_inventory_requests_total)' || true)"
  if PROM_JSON="$RESPONSE" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ["PROM_JSON"])
except json.JSONDecodeError:
    sys.exit(1)

result = payload.get("data", {}).get("result", [])
if not result:
    sys.exit(1)

value = float(result[0]["value"][1])
sys.exit(0 if value >= 2 else 1)
PY
  then
    echo "ready: app metrics"
    break
  fi
  sleep 2
done

for _ in $(seq 1 30); do
  RESPONSE="$(curl -fsS --get "http://127.0.0.1:${VM_PORT}/api/v1/query" --data-urlencode 'query=sum(up{job=~"victoria-metrics|victoria-logs|victoria-traces|otel-collector|checkout-api|inventory-api"})' || true)"
  if PROM_JSON="$RESPONSE" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ["PROM_JSON"])
except json.JSONDecodeError:
    sys.exit(1)

result = payload.get("data", {}).get("result", [])
if not result:
    sys.exit(1)

value = float(result[0]["value"][1])
sys.exit(0 if value >= 6 else 1)
PY
  then
    echo "ready: backend scrape metrics"
    break
  fi
  sleep 2
done

for _ in $(seq 1 30); do
  LOG_RESPONSE="$(curl -fsS -X POST "http://127.0.0.1:${VL_PORT}/select/logsql/query" \
    -d "query=_time:15m trace_id:=\"$TRACE_ID\" | sort by (_time) desc | limit 20" || true)"
  if LOG_RESPONSE="$LOG_RESPONSE" TRACE_ID="$TRACE_ID" python3 - <<'PY'
import json
import os
import sys

lines = [line for line in os.environ["LOG_RESPONSE"].splitlines() if line.strip()]
if not lines:
    sys.exit(1)

services = set()
matched_trace = False
for line in lines:
    try:
        payload = json.loads(line)
    except json.JSONDecodeError:
        continue
    msg = payload.get("_msg", "")
    trace_id = payload.get("trace_id", "")
    if trace_id == os.environ["TRACE_ID"]:
        matched_trace = True
    service = payload.get("service.name") or payload.get("service_name")
    if not service and msg:
        try:
            msg_payload = json.loads(msg)
        except json.JSONDecodeError:
            msg_payload = {}
        service = msg_payload.get("service") or msg_payload.get("service_name")
    if service:
        services.add(service)

if matched_trace and {"checkout-api", "inventory-api"}.issubset(services):
    sys.exit(0)
sys.exit(1)
PY
  then
    echo "ready: victoria-logs query"
    break
  fi
  sleep 2
done

for _ in $(seq 1 30); do
  TRACE_RESPONSE="$(curl -fsS "http://127.0.0.1:${VT_PORT}/select/jaeger/api/traces/${TRACE_ID}" || true)"
  if TRACE_RESPONSE="$TRACE_RESPONSE" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ["TRACE_RESPONSE"])
except json.JSONDecodeError:
    sys.exit(1)

data = payload.get("data") or []
if not data:
    sys.exit(1)

trace = data[0]
processes = trace.get("processes", {})
services = set()
for span in trace.get("spans", []):
    process = processes.get(span.get("processID", ""), {})
    service = process.get("serviceName")
    if service:
        services.add(service)

if {"checkout-api", "inventory-api"}.issubset(services):
    sys.exit(0)
sys.exit(1)
PY
  then
    echo "ready: victoria-traces query"
    echo "smoke test passed"
    exit 0
  fi
  sleep 2
done

echo "timed out waiting for full metrics/logs/traces correlation" >&2
exit 1
