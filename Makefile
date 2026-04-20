SHELL := /bin/bash

NAMESPACE ?= observability

.PHONY: help bootstrap smoke port-forward-grafana port-forward-checkout loadgen-up loadgen-down

help:
	@printf "%s\n" \
	  "Targets:" \
	  "  make bootstrap            Install/update Victoria stack and demo app on k3s" \
	  "  make smoke                Run the local smoke test" \
	  "  make port-forward-grafana Expose Grafana on localhost:3000" \
	  "  make port-forward-checkout Expose checkout-api on localhost:8000" \
	  "  make loadgen-up           Start optional synthetic traffic" \
	  "  make loadgen-down         Stop optional synthetic traffic"

bootstrap:
	./scripts/bootstrap.sh

smoke:
	./scripts/smoke.sh

port-forward-grafana:
	kubectl -n $(NAMESPACE) port-forward svc/grafana 3000:80

port-forward-checkout:
	kubectl -n $(NAMESPACE) port-forward svc/checkout-api 8000:8000

loadgen-up:
	./scripts/kustomize-render.sh k8s/optional | kubectl -n $(NAMESPACE) apply -f -

loadgen-down:
	./scripts/kustomize-render.sh k8s/optional | kubectl -n $(NAMESPACE) delete --ignore-not-found -f -
