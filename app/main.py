"""
Sample instrumented service — emits traces and metrics via OpenTelemetry.
Runs directly on the server via systemd (no Docker).
"""
import time, random, os, logging
from fastapi import FastAPI, Response
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

resource = Resource.create({"service.name": "sample-app", "service.version": "1.0.0"})
provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317"), insecure=True)
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)

REQUEST_COUNT = Counter("http_requests_total", "Total HTTP requests", ["method", "endpoint", "status"])
REQUEST_DURATION = Histogram("http_request_duration_seconds", "Request duration", ["method", "endpoint"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0])
INCIDENT_MTTR = Gauge("incident_mttr_seconds", "MTTR for last incident")

app = FastAPI(title="Sample Instrumented App")
FastAPIInstrumentor.instrument_app(app)

def record(method, endpoint, status, duration):
    REQUEST_COUNT.labels(method=method, endpoint=endpoint, status=str(status)).inc()
    REQUEST_DURATION.labels(method=method, endpoint=endpoint).observe(duration)

@app.get("/")
async def root():
    start = time.time()
    with tracer.start_as_current_span("root") as span:
        ctx = trace.get_current_span().get_span_context()
        logger.info(f"Root request traceID={format(ctx.trace_id, '032x')}")
    record("GET", "/", 200, time.time() - start)
    return {"status": "healthy", "service": "sample-app"}

@app.get("/api/fast")
async def fast():
    start = time.time()
    with tracer.start_as_current_span("fast-handler"):
        delay = max(0, random.gauss(0.05, 0.02))
        time.sleep(delay)
        ctx = trace.get_current_span().get_span_context()
        logger.info(f"Fast request {delay:.3f}s traceID={format(ctx.trace_id, '032x')}")
    record("GET", "/api/fast", 200, time.time() - start)
    return {"latency_ms": round(delay * 1000, 2)}

@app.get("/api/slow")
async def slow():
    """Use this for Game Day Scenario 2 — inject latency"""
    start = time.time()
    with tracer.start_as_current_span("slow-handler"):
        delay = max(0.1, random.gauss(0.3, 0.1))
        time.sleep(delay)
        ctx = trace.get_current_span().get_span_context()
        logger.warning(f"Slow request {delay:.3f}s traceID={format(ctx.trace_id, '032x')}")
    record("GET", "/api/slow", 200, time.time() - start)
    return {"latency_ms": round(delay * 1000, 2)}

@app.get("/api/fail")
async def fail():
    """30% error rate — use for SLO burn rate testing"""
    start = time.time()
    with tracer.start_as_current_span("fail-handler") as span:
        if random.random() < 0.3:
            span.set_attribute("error", True)
            ctx = trace.get_current_span().get_span_context()
            logger.error(f"Request failed traceID={format(ctx.trace_id, '032x')}")
            record("GET", "/api/fail", 500, time.time() - start)
            return Response(content='{"error":"internal server error"}', status_code=500, media_type="application/json")
    record("GET", "/api/fail", 200, time.time() - start)
    return {"status": "ok"}

@app.post("/incident")
async def record_incident(mttr_seconds: float):
    """Call this after resolving an incident: curl -X POST 'http://SERVER:8000/incident?mttr_seconds=3600'"""
    INCIDENT_MTTR.set(mttr_seconds)
    return {"mttr_seconds": mttr_seconds}

@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
