import atexit
import json
import logging
import os
import sys
from typing import Any

from opentelemetry import trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode


_REQUESTS_INSTRUMENTED = False
_REDIS_INSTRUMENTED = False


def _resource(service_name: str) -> Resource:
    return Resource.create(
        {
            "service.name": service_name,
            "service.namespace": os.getenv("APP_SERVICE_NAMESPACE", "victoria-k3s-template"),
            "deployment.environment": os.getenv("APP_DEPLOYMENT_ENVIRONMENT", "local-k3s"),
        }
    )


def current_trace_id() -> str:
    span_context = trace.get_current_span().get_span_context()
    if not span_context.is_valid:
        return ""
    return f"{span_context.trace_id:032x}"


def current_span_id() -> str:
    span_context = trace.get_current_span().get_span_context()
    if not span_context.is_valid:
        return ""
    return f"{span_context.span_id:016x}"


def configure_telemetry(service_name: str, app: Any | None = None) -> logging.Logger:
    global _REQUESTS_INSTRUMENTED, _REDIS_INSTRUMENTED

    endpoint = os.getenv("APP_OTLP_GRPC_ENDPOINT", "http://otel-collector:4317")
    resource = _resource(service_name)

    tracer_provider = TracerProvider(resource=resource)
    span_exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
    tracer_provider.add_span_processor(BatchSpanProcessor(span_exporter))
    trace.set_tracer_provider(tracer_provider)

    logger_provider = LoggerProvider(resource=resource)
    log_exporter = OTLPLogExporter(endpoint=endpoint, insecure=True)
    logger_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))
    set_logger_provider(logger_provider)

    otel_handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(logging.Formatter("%(message)s"))

    root_logger = logging.getLogger()
    root_logger.handlers.clear()
    root_logger.setLevel(logging.INFO)
    root_logger.addHandler(console_handler)
    root_logger.addHandler(otel_handler)

    if not _REQUESTS_INSTRUMENTED:
        RequestsInstrumentor().instrument()
        _REQUESTS_INSTRUMENTED = True

    if not _REDIS_INSTRUMENTED:
        RedisInstrumentor().instrument()
        _REDIS_INSTRUMENTED = True

    if app is not None:
        FastAPIInstrumentor.instrument_app(app, excluded_urls="/metrics,/healthz")

    atexit.register(tracer_provider.shutdown)
    atexit.register(logger_provider.shutdown)

    return logging.getLogger(service_name)


def emit_log(
    logger: logging.Logger,
    service_name: str,
    level: str,
    message: str,
    **fields: Any,
) -> None:
    payload = {
        "timestamp": fields.pop("timestamp", None),
        "level": level.upper(),
        "service": service_name,
        "message": message,
        "trace_id": current_trace_id(),
        "span_id": current_span_id(),
        **fields,
    }
    if payload["timestamp"] is None:
        payload["timestamp"] = ""
    getattr(logger, level.lower())(json.dumps(payload, sort_keys=True))


def mark_span_error(exc: Exception) -> None:
    span = trace.get_current_span()
    if span is None:
        return
    span.record_exception(exc)
    span.set_status(Status(StatusCode.ERROR, str(exc)))
