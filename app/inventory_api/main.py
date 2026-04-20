import os
import time
from datetime import datetime, timezone

import redis
from fastapi import FastAPI
from fastapi.responses import JSONResponse, Response
from opentelemetry import trace
from prometheus_client import Counter, Histogram, REGISTRY
from prometheus_client.openmetrics.exposition import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field

from common.telemetry import configure_telemetry, current_trace_id, emit_log, mark_span_error


SERVICE_NAME = os.getenv("APP_SERVICE_NAME", "inventory-api")
REDIS_URL = os.getenv("APP_REDIS_URL", "redis://redis:6379/1")

app = FastAPI(title="inventory-api")
logger = configure_telemetry(SERVICE_NAME, app=app)
tracer = trace.get_tracer(SERVICE_NAME)
redis_client = redis.Redis.from_url(REDIS_URL, decode_responses=True)


inventory_requests_total = Counter(
    "demo_inventory_requests_total",
    "Total inventory requests",
    ["service", "mode", "outcome"],
)
inventory_duration_seconds = Histogram(
    "demo_inventory_duration_seconds",
    "Inventory duration in seconds",
    ["service", "mode", "outcome"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5),
)
redis_cache_hits_total = Counter(
    "demo_redis_cache_hits_total",
    "Redis cache hits observed by the demo app",
    ["service", "result"],
)


class ReservationRequest(BaseModel):
    order_id: str
    user_id: str
    sku: str = Field(default="sku-1")
    quantity: int = Field(default=1, ge=1)
    mode: str = Field(default="ok")


@app.on_event("startup")
def on_startup() -> None:
    redis_client.ping()
    for sku in ("sku-1", "sku-2", "sku-3"):
        key = f"stock:{sku}"
        if redis_client.get(key) is None:
            redis_client.set(key, 200)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "service": SERVICE_NAME}


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)


@app.post("/api/reserve")
def reserve(payload: ReservationRequest) -> JSONResponse:
    started = time.perf_counter()
    outcome = "ok"
    inventory_status = "reserved"
    trace_id = current_trace_id()

    current_span = trace.get_current_span()
    current_span.set_attribute("app.order_id", payload.order_id)
    current_span.set_attribute("app.user_id", payload.user_id)
    current_span.set_attribute("app.sku", payload.sku)
    current_span.set_attribute("app.mode", payload.mode)
    current_span.set_attribute("app.quantity", payload.quantity)

    emit_log(
        logger,
        SERVICE_NAME,
        "info",
        "inventory_started",
        timestamp=datetime.now(timezone.utc).isoformat(),
        order_id=payload.order_id,
        user_id=payload.user_id,
        sku=payload.sku,
        mode=payload.mode,
        outcome="started",
        error="",
    )

    try:
        if payload.mode == "slow":
            time.sleep(1.1)
        else:
            time.sleep(0.05)

        if payload.mode == "fail_inventory":
            raise RuntimeError("forced inventory failure")

        with tracer.start_as_current_span("inventory.redis_reservation") as span:
            stock_key = f"stock:{payload.sku}"
            current_stock = int(redis_client.get(stock_key) or 0)
            redis_cache_hits_total.labels(service=SERVICE_NAME, result="hit").inc(
                exemplar={"trace_id": current_trace_id()}
            )
            if current_stock < payload.quantity:
                raise RuntimeError("insufficient stock")

            remaining = current_stock - payload.quantity
            redis_client.set(stock_key, remaining)
            redis_client.hset(
                f"reservation:{payload.order_id}",
                mapping={
                    "user_id": payload.user_id,
                    "sku": payload.sku,
                    "quantity": payload.quantity,
                    "status": "reserved",
                },
            )
            span.set_attribute("app.stock_before", current_stock)
            span.set_attribute("app.stock_after", remaining)

        response_payload = {
            "order_id": payload.order_id,
            "inventory_status": inventory_status,
            "trace_id": current_trace_id() or trace_id,
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
            "inventory_failed",
            timestamp=datetime.now(timezone.utc).isoformat(),
            order_id=payload.order_id,
            user_id=payload.user_id,
            sku=payload.sku,
            mode=payload.mode,
            outcome=outcome,
            error=str(exc),
        )
        response_payload = {
            "order_id": payload.order_id,
            "inventory_status": inventory_status,
            "trace_id": current_trace_id() or trace_id,
        }
        status_code = 503
    finally:
        duration = time.perf_counter() - started
        exemplar = {"trace_id": current_trace_id() or trace_id}
        inventory_requests_total.labels(service=SERVICE_NAME, mode=payload.mode, outcome=outcome).inc(exemplar=exemplar)
        inventory_duration_seconds.labels(service=SERVICE_NAME, mode=payload.mode, outcome=outcome).observe(
            duration,
            exemplar=exemplar,
        )
        emit_log(
            logger,
            SERVICE_NAME,
            "info",
            "inventory_finished",
            timestamp=datetime.now(timezone.utc).isoformat(),
            order_id=payload.order_id,
            user_id=payload.user_id,
            sku=payload.sku,
            mode=payload.mode,
            outcome=outcome,
            error="" if outcome == "ok" else "inventory_failed",
            inventory_status=inventory_status,
            duration_ms=round(duration * 1000, 2),
        )

    return JSONResponse(status_code=status_code, content=response_payload)
