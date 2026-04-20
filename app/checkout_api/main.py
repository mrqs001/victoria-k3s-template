import os
import time
import uuid
from datetime import datetime, timezone

import redis
import requests
from fastapi import FastAPI
from fastapi.responses import JSONResponse, Response
from opentelemetry import trace
from prometheus_client import Counter, Histogram, REGISTRY
from prometheus_client.openmetrics.exposition import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field

from common.telemetry import configure_telemetry, current_trace_id, emit_log, mark_span_error


SERVICE_NAME = os.getenv("APP_SERVICE_NAME", "checkout-api")
PORT = int(os.getenv("APP_PORT", "8000"))
REDIS_URL = os.getenv("APP_REDIS_URL", "redis://redis:6379/0")
INVENTORY_BASE_URL = os.getenv("APP_INVENTORY_BASE_URL", "http://inventory-api:8001")

app = FastAPI(title="checkout-api")
logger = configure_telemetry(SERVICE_NAME, app=app)
tracer = trace.get_tracer(SERVICE_NAME)
redis_client = redis.Redis.from_url(REDIS_URL, decode_responses=True)


checkout_requests_total = Counter(
    "demo_checkout_requests_total",
    "Total checkout requests",
    ["service", "mode", "outcome"],
)
checkout_duration_seconds = Histogram(
    "demo_checkout_duration_seconds",
    "Checkout duration in seconds",
    ["service", "mode", "outcome"],
    buckets=(0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5),
)
redis_cache_hits_total = Counter(
    "demo_redis_cache_hits_total",
    "Redis cache hits observed by the demo app",
    ["service", "result"],
)


class CheckoutRequest(BaseModel):
    user_id: str = Field(default="demo-user")
    sku: str = Field(default="sku-1")
    quantity: int = Field(default=1, ge=1)
    mode: str = Field(default="ok")


@app.on_event("startup")
def on_startup() -> None:
    redis_client.ping()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "service": SERVICE_NAME}


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)


@app.post("/api/checkout")
def checkout(payload: CheckoutRequest) -> JSONResponse:
    started = time.perf_counter()
    order_id = uuid.uuid4().hex
    trace_id = current_trace_id()
    cache_hit = False
    inventory_status = "unknown"
    outcome = "ok"

    current_span = trace.get_current_span()
    current_span.set_attribute("app.order_id", order_id)
    current_span.set_attribute("app.user_id", payload.user_id)
    current_span.set_attribute("app.sku", payload.sku)
    current_span.set_attribute("app.mode", payload.mode)
    current_span.set_attribute("app.quantity", payload.quantity)

    emit_log(
        logger,
        SERVICE_NAME,
        "info",
        "checkout_started",
        timestamp=datetime.now(timezone.utc).isoformat(),
        order_id=order_id,
        user_id=payload.user_id,
        sku=payload.sku,
        mode=payload.mode,
        outcome="started",
        error="",
    )

    try:
        with tracer.start_as_current_span("checkout.load_price_cache") as span:
            price_key = f"price:{payload.sku}"
            cached_price = redis_client.get(price_key)
            cache_hit = cached_price is not None
            redis_cache_hits_total.labels(service=SERVICE_NAME, result="hit" if cache_hit else "miss").inc(
                exemplar={"trace_id": current_trace_id()}
            )
            if not cache_hit:
                cached_price = str(1999 + len(payload.sku) * 10)
                redis_client.setex(price_key, 600, cached_price)
            span.set_attribute("app.cache_hit", cache_hit)
            span.set_attribute("app.price_cents", int(cached_price))

        with tracer.start_as_current_span("checkout.reserve_inventory") as span:
            response = requests.post(
                f"{INVENTORY_BASE_URL}/api/reserve",
                json={
                    "order_id": order_id,
                    "user_id": payload.user_id,
                    "sku": payload.sku,
                    "quantity": payload.quantity,
                    "mode": payload.mode,
                },
                timeout=5,
            )
            inventory_payload = response.json()
            inventory_status = inventory_payload.get("inventory_status", "unknown")
            span.set_attribute("http.status_code", response.status_code)
            span.set_attribute("app.inventory_status", inventory_status)
            if response.status_code >= 400:
                raise requests.HTTPError(response.text, response=response)

        response_payload = {
            "order_id": order_id,
            "status": "ok",
            "trace_id": current_trace_id() or trace_id,
            "inventory_status": inventory_status,
            "cache_hit": cache_hit,
        }
        status_code = 200
    except Exception as exc:
        outcome = "error"
        inventory_status = "failed"
        mark_span_error(exc)
        emit_log(
            logger,
            SERVICE_NAME,
            "error",
            "checkout_failed",
            timestamp=datetime.now(timezone.utc).isoformat(),
            order_id=order_id,
            user_id=payload.user_id,
            sku=payload.sku,
            mode=payload.mode,
            outcome=outcome,
            error=str(exc),
        )
        response_payload = {
            "order_id": order_id,
            "status": "error",
            "trace_id": current_trace_id() or trace_id,
            "inventory_status": inventory_status,
            "cache_hit": cache_hit,
        }
        status_code = 502
    finally:
        duration = time.perf_counter() - started
        exemplar = {"trace_id": current_trace_id() or trace_id}
        checkout_requests_total.labels(service=SERVICE_NAME, mode=payload.mode, outcome=outcome).inc(exemplar=exemplar)
        checkout_duration_seconds.labels(service=SERVICE_NAME, mode=payload.mode, outcome=outcome).observe(
            duration,
            exemplar=exemplar,
        )
        emit_log(
            logger,
            SERVICE_NAME,
            "info",
            "checkout_finished",
            timestamp=datetime.now(timezone.utc).isoformat(),
            order_id=order_id,
            user_id=payload.user_id,
            sku=payload.sku,
            mode=payload.mode,
            outcome=outcome,
            error="" if outcome == "ok" else "checkout_failed",
            inventory_status=inventory_status,
            cache_hit=cache_hit,
            duration_ms=round(duration * 1000, 2),
        )

    return JSONResponse(status_code=status_code, content=response_payload)
