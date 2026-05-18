"""
fake-service/app.py

A self-contained fake service that emits all Four Golden Signals:
  - Latency   → http_request_duration_seconds (histogram)
  - Traffic   → http_requests_total (counter)
  - Errors    → http_requests_total{status="5xx"} (counter)
  - Saturation→ process_cpu_usage, process_memory_usage (gauge)

Also emits:
  - Structured logs  → via OTel → OTel Collector → Loki
  - Distributed traces → via OTel → OTel Collector → Tempo
"""

import os
import time
import random
import logging
import threading

from flask import Flask, jsonify, request, Response

# ── Prometheus client ─────────────────────────────────────────────────────────
from prometheus_client import (
    Counter, Histogram, Gauge,
    generate_latest, CONTENT_TYPE_LATEST,
)

# ── OpenTelemetry ─────────────────────────────────────────────────────────────
from opentelemetry import trace, metrics as otel_metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry._logs import set_logger_provider
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────
OTEL_ENDPOINT = os.getenv("OTEL_ENDPOINT", "http://localhost:4317")
SERVICE_NAME = os.getenv("SERVICE_NAME", "fake-service")

# ─────────────────────────────────────────────────────────────────────────────
# OPENTELEMETRY SETUP
# ─────────────────────────────────────────────────────────────────────────────
resource = Resource.create({"service.name": SERVICE_NAME})

# Traces
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True))
)
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer(SERVICE_NAME)

# Metrics (OTel — separate from Prometheus, gives you OTLP metrics in Tempo)
metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=OTEL_ENDPOINT, insecure=True),
    export_interval_millis=15000,
)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
otel_metrics.set_meter_provider(meter_provider)

# Logs → OTel → Loki
logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(
    BatchLogRecordProcessor(OTLPLogExporter(endpoint=OTEL_ENDPOINT, insecure=True))
)
set_logger_provider(logger_provider)

otel_handler = LoggingHandler(level=logging.DEBUG, logger_provider=logger_provider)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(SERVICE_NAME)
logger.addHandler(otel_handler)

# ─────────────────────────────────────────────────────────────────────────────
# PROMETHEUS METRICS  (Four Golden Signals)
# ─────────────────────────────────────────────────────────────────────────────

# LATENCY — how long requests take
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "endpoint", "status_code"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
)

# TRAFFIC — requests per second
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status_code"],
)

# SATURATION — how full the system is
CPU_USAGE = Gauge(
    "process_cpu_usage_percent",
    "Simulated CPU usage percentage",
)
MEMORY_USAGE = Gauge(
    "process_memory_usage_percent",
    "Simulated memory usage percentage",
)
ACTIVE_CONNECTIONS = Gauge(
    "http_active_connections",
    "Simulated number of active connections",
)

# ─────────────────────────────────────────────────────────────────────────────
# FLASK APP
# ─────────────────────────────────────────────────────────────────────────────
app = Flask(__name__)

ENDPOINTS = ["/api/users", "/api/orders", "/api/products", "/api/checkout", "/api/search"]


def weighted_status():
    """Return a realistic status code distribution."""
    return random.choices(
        [200, 200, 200, 200, 200, 201, 400, 500, 503],
        weights=[60, 5, 5, 5, 5, 5, 8, 5, 2],
    )[0]


def weighted_latency(status_code):
    """
    Errors tend to be slower (timeout-style).
    Happy path: 10ms–400ms. Error path: 200ms–2s.
    """
    if status_code >= 500:
        return random.uniform(0.2, 2.0)
    elif status_code >= 400:
        return random.uniform(0.05, 0.3)
    else:
        return random.choices(
            # p50~80ms, p95~350ms, occasional spike
            [random.uniform(0.01, 0.15),
             random.uniform(0.15, 0.5),
             random.uniform(0.5, 2.5)],
            weights=[80, 15, 5],
        )[0]


@app.route("/metrics")
def metrics():
    """Prometheus scrape endpoint."""
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.route("/health")
def health():
    return jsonify({"status": "ok", "service": SERVICE_NAME})


@app.route("/simulate", methods=["POST"])
def simulate_request():
    """
    Manually trigger a single simulated request.
    Body: { "endpoint": "/api/orders", "force_error": true }
    """
    body = request.get_json(silent=True) or {}
    endpoint = body.get("endpoint", random.choice(ENDPOINTS))
    force_err = body.get("force_error", False)

    status = 500 if force_err else weighted_status()
    _record_request("POST", endpoint, status)
    return jsonify({"simulated": True, "endpoint": endpoint, "status": status})


def _record_request(method, endpoint, status_code):
    """Record one request across Prometheus metrics + OTel trace + log."""
    latency = weighted_latency(status_code)
    status_str = str(status_code)

    # ── Prometheus ────────────────────────────────────────
    REQUEST_LATENCY.labels(method, endpoint, status_str).observe(latency)
    REQUEST_COUNT.labels(method, endpoint, status_str).inc()

    # ── OTel Trace ────────────────────────────────────────
    with tracer.start_as_current_span(
        f"{method} {endpoint}",
        kind=trace.SpanKind.SERVER,
    ) as span:
        span.set_attribute("http.method", method)
        span.set_attribute("http.route", endpoint)
        span.set_attribute("http.status_code", status_code)
        span.set_attribute("http.duration_ms", round(latency * 1000, 2))

        if status_code >= 500:
            span.set_status(trace.StatusCode.ERROR, f"HTTP {status_code}")

        # Simulate a downstream DB call inside the span
        with tracer.start_as_current_span("db.query") as db_span:
            db_span.set_attribute("db.system", "postgresql")
            db_span.set_attribute("db.statement", f"SELECT * FROM {endpoint.split('/')[-1]}")
            time.sleep(latency * 0.6)   # DB takes 60% of total latency

        time.sleep(latency * 0.4)       # Remaining in app logic

        # ── Structured log tied to this trace ─────────────
        trace_id = format(span.get_span_context().trace_id, "032x")
        log_level = logging.ERROR if status_code >= 500 else (
            logging.WARNING if status_code >= 400 else logging.INFO)

        logger.log(
            log_level,
            f'{method} {endpoint} → {status_code} in {latency*1000:.1f}ms',
            extra={
                "traceID": trace_id,
                "endpoint": endpoint,
                "status_code": status_code,
                "latency_ms": round(latency * 1000, 2),
                "service": SERVICE_NAME,
            }
        )

# ─────────────────────────────────────────────────────────────────────────────
# BACKGROUND SATURATION SIMULATOR
# Updates CPU/memory/connection gauges with realistic wave patterns
# ─────────────────────────────────────────────────────────────────────────────


def saturation_simulator():
    """
    Simulates saturation metrics with slow oscillation + occasional spikes.
    CPU and memory rise and fall over time; connections track traffic load.
    """
    t = 0
    while True:
        import math

        # Base oscillation — CPU cycles between ~20% and ~65%
        cpu_base = 40 + 25 * math.sin(t / 60)
        cpu_noise = random.uniform(-5, 5)
        cpu_spike = 30 if random.random() < 0.02 else 0   # 2% chance of spike
        cpu = min(99, max(1, cpu_base + cpu_noise + cpu_spike))

        # Memory grows slowly then drops (GC-style pattern)
        mem_base = 50 + 20 * math.sin(t / 120)
        mem_noise = random.uniform(-3, 3)
        memory = min(95, max(20, mem_base + mem_noise))

        # Active connections track CPU loosely
        connections = int(cpu * 2 + random.uniform(-10, 10))

        CPU_USAGE.set(round(cpu, 2))
        MEMORY_USAGE.set(round(memory, 2))
        ACTIVE_CONNECTIONS.set(max(0, connections))

        t += 5
        time.sleep(5)

# ─────────────────────────────────────────────────────────────────────────────
# TRAFFIC SIMULATOR
# Drives realistic request patterns — day/night load variation
# ─────────────────────────────────────────────────────────────────────────────


def traffic_simulator():
    """
    Simulates traffic load: ramps up, sustains, introduces error bursts.
    Runs continuously, sending requests at a realistic RPS.
    """
    import math

    t = 0
    while True:
        # RPS oscillates: ~5 rps at night, ~30 rps at peak
        rps = 15 + 12 * math.sin(t / 90) + random.uniform(-2, 2)
        rps = max(2, rps)

        # Occasional error burst (simulates a bad deploy or upstream failure)
        error_burst = random.random() < 0.03  # 3% of cycles

        # Send a batch of requests for this second
        batch_size = max(1, int(rps))
        for _ in range(batch_size):
            endpoint = random.choice(ENDPOINTS)
            method = random.choices(["GET", "POST", "PUT"], weights=[70, 20, 10])[0]
            status = 500 if error_burst else weighted_status()
            _record_request(method, endpoint, status)

        if error_burst:
            logger.error(
                f"Error burst active — {batch_size} requests sent with 500s",
                extra={"service": SERVICE_NAME, "event": "error_burst"}
            )

        t += 1
        time.sleep(1)


# ─────────────────────────────────────────────────────────────────────────────
# STARTUP
# ─────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    logger.info(f"Starting {SERVICE_NAME}", extra={"service": SERVICE_NAME})

    # Start background simulators
    threading.Thread(target=saturation_simulator, daemon=True).start()
    threading.Thread(target=traffic_simulator, daemon=True).start()

    app.run(host="0.0.0.0", port=8080)
