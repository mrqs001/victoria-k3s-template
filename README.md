# victoria-k3s-template

Local-first observability starter for `k3s` with VictoriaMetrics for metrics, VictoriaLogs for logs, VictoriaTraces for traces, Grafana for visualization, an OpenTelemetry Collector, and a small FastAPI demo app.

This repository is the Victoria-oriented successor to the old LGTM Docker Compose starter. The target environment is a single-node `k3s` cluster on your computer, not `docker compose`.

## What This Repository Includes

- `k3s` bootstrap guidance for a local single-node cluster
- Helm-managed single-node Victoria backends:
  - VictoriaMetrics
  - VictoriaLogs
  - VictoriaTraces
  - Grafana
- OpenTelemetry Collector deployed in Kubernetes
- A small two-service FastAPI demo app plus Redis
- GitHub Actions to validate the repo and publish the demo app image to GHCR

## Architecture

```text
checkout-api -> inventory-api -> Redis
checkout-api -> OTel Collector -> VictoriaLogs
checkout-api -> OTel Collector -> VictoriaTraces
inventory-api -> OTel Collector -> VictoriaLogs
inventory-api -> OTel Collector -> VictoriaTraces
OTel Collector -> scrape /metrics -> VictoriaMetrics
Grafana -> VictoriaMetrics datasource plugin
Grafana -> VictoriaLogs datasource plugin
Grafana -> Jaeger datasource backed by VictoriaTraces
```

## Important Product Difference

The previous LGTM starter relied on Tempo exemplars for metric-to-trace jumps. VictoriaMetrics does not support exemplars, so this template leans on:

- shared labels and trace IDs
- Grafana correlations
- Grafana Explore across metrics, logs, and traces

That is an intentional design constraint of the Victoria stack, not a missing piece in this repo.

## Repo Layout

```text
.
├── app/                    Demo services and shared telemetry code
├── charts-values/          Helm values for Victoria components and Grafana
├── k8s/
│   ├── base/               Demo app, Redis, collector, namespace
│   └── optional/           Synthetic traffic deployment
├── scripts/                Cluster bootstrap and smoke test helpers
├── .github/workflows/      Validation and image publishing
└── Makefile
```

## Quick Start

### 1. Install k3s

Use the official install script from the k3s docs:

```bash
curl -sfL https://get.k3s.io | sh -
```

The checked-in helper script wraps the same flow and sets a readable kubeconfig mode:

```bash
./scripts/install-k3s.sh
```

Official reference:
- https://docs.k3s.io/quick-start

### 2. Push the repo and wait for the demo app image

The deployment manifests expect this image:

```text
ghcr.io/mrqs001/victoria-k3s-template-demo-app:main
```

That image is built by GitHub Actions on push to `main`.

### 3. Bootstrap the stack

```bash
make bootstrap
```

This installs:

- `victoria-metrics-single`
- `victoria-logs-single`
- `victoria-traces-single`
- `grafana`
- `redis`
- `otel-collector`
- `checkout-api`
- `inventory-api`

Override points:

```bash
NAMESPACE=my-observability APP_IMAGE=ghcr.io/my-user/my-app:main make bootstrap
```

`APP_IMAGE` defaults to the demo image published by this repository. That makes it straightforward to reuse this repo with your own prebuilt service image later.

### 4. Expose the app and Grafana locally

In separate terminals:

```bash
make port-forward-checkout
make port-forward-grafana
```

Grafana will be available at `http://localhost:3000`.

Default credentials:

- user: `admin`
- password: `admin`

### 5. Generate a request

```bash
curl -X POST http://localhost:8000/api/checkout \
  -H 'Content-Type: application/json' \
  -d '{"user_id":"demo-user","sku":"sku-1","quantity":1,"mode":"ok"}'
```

### 6. Run the smoke test

```bash
make smoke
```

## Optional Synthetic Traffic

```bash
make loadgen-up
```

To stop it:

```bash
make loadgen-down
```

## Current Scope

This repo is intentionally local-first:

- single-node Victoria deployments
- no TLS between in-cluster components
- no auth on internal services
- no production ingress setup
- no object storage
- no horizontal scaling

That keeps it easy to understand, easy to run, and easy to adapt into a real app base later.

## Reuse Notes

The easiest way to adapt this to a real app is:

1. Build and publish your own image.
2. Set `APP_IMAGE=ghcr.io/you/your-image:tag`.
3. Replace the demo manifests under `k8s/base/` with your services while keeping the collector and Victoria backends.

The manifests intentionally avoid a hard-coded namespace so the bootstrap scripts can target any namespace.

## Official References Used For This Scaffold

- k3s quick start: https://docs.k3s.io/quick-start
- VictoriaMetrics OTLP metrics ingestion: https://docs.victoriametrics.com/victoriametrics/data-ingestion/opentelemetry-collector/
- VictoriaLogs OTLP logs ingestion: https://docs.victoriametrics.com/victorialogs/data-ingestion/opentelemetry/
- VictoriaTraces OTLP traces ingestion: https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/
- VictoriaMetrics Grafana datasource: https://docs.victoriametrics.com/victoriametrics/integrations/grafana/datasource/
- VictoriaLogs Grafana datasource: https://docs.victoriametrics.com/victorialogs/integrations/grafana/
- VictoriaTraces in Grafana via Jaeger datasource: https://docs.victoriametrics.com/victoriatraces/querying/grafana/
