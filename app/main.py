from fastapi import FastAPI, Response, Request
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, Gauge, generate_latest
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from tenacity import (
    retry,
    stop_after_attempt,
    wait_exponential,
    retry_if_exception_type,
    before_sleep_log,
)
from contextlib import asynccontextmanager
import time
import random
import os
import json
import logging
import sys
import asyncio
import threading

# ── Structured JSON logging ───────────────────────────────────────────────────
class JsonFormatter(logging.Formatter):
    def format(self, record):
        log = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        if hasattr(record, "extra"):
            log.update(record.extra)
        return json.dumps(log)

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logger = logging.getLogger("cloud-lab")
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# ── Config from environment ───────────────────────────────────────────────────
ERROR_RATE        = float(os.getenv("APP_ERROR_RATE", "0.30"))
LATENCY_SECONDS   = float(os.getenv("APP_LATENCY_SECONDS", "0.2"))
JAEGER_ENDPOINT   = os.getenv("JAEGER_ENDPOINT", "http://jaeger:4317")
CIRCUIT_THRESHOLD = float(os.getenv("CIRCUIT_THRESHOLD", "0.50"))  # open at 50% errors
CIRCUIT_TIMEOUT   = int(os.getenv("CIRCUIT_TIMEOUT", "30"))        # seconds before half-open

# ── OpenTelemetry setup ───────────────────────────────────────────────────────
resource = Resource.create({"service.name": "cloud-lab-api", "service.version": "1.0.0"})
provider = TracerProvider(resource=resource)

try:
    otlp_exporter = OTLPSpanExporter(endpoint=JAEGER_ENDPOINT, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(otlp_exporter))
    logger.info("OpenTelemetry connected to Jaeger", extra={"endpoint": JAEGER_ENDPOINT})
except Exception as e:
    logger.warning("OpenTelemetry export unavailable — traces will not be sent",
                   extra={"error": str(e)})

trace.set_tracer_provider(provider)
tracer = trace.get_tracer("cloud-lab")

# ── Circuit breaker state ─────────────────────────────────────────────────────
class CircuitBreaker:
    """
    Three states:
      CLOSED   — normal operation, requests flow through
      OPEN     — too many errors, reject all requests with 503
      HALF_OPEN — trial period after timeout, one request allowed through
    """
    CLOSED    = "closed"
    OPEN      = "open"
    HALF_OPEN = "half_open"

    def __init__(self, threshold: float, timeout: int):
        self.threshold   = threshold   # error rate that trips the breaker
        self.timeout     = timeout     # seconds before trying half-open
        self.state       = self.CLOSED
        self.error_count = 0
        self.total_count = 0
        self.opened_at   = None
        self._lock       = threading.Lock()

    def record_success(self):
        with self._lock:
            self.total_count += 1
            if self.state == self.HALF_OPEN:
                # Trial request succeeded — close the breaker
                logger.info("Circuit breaker closing — trial request succeeded")
                self.state       = self.CLOSED
                self.error_count = 0
                self.total_count = 0

    def record_failure(self):
        with self._lock:
            self.total_count += 1
            self.error_count += 1
            if self.state == self.HALF_OPEN:
                # Trial request failed — reopen
                logger.warning("Circuit breaker reopening — trial request failed")
                self.state     = self.OPEN
                self.opened_at = time.time()
                return
            if self.total_count >= 10:
                rate = self.error_count / self.total_count
                if rate >= self.threshold and self.state == self.CLOSED:
                    logger.warning("Circuit breaker opening",
                                   extra={"error_rate": rate, "threshold": self.threshold})
                    self.state     = self.OPEN
                    self.opened_at = time.time()
                    CIRCUIT_STATE.labels(state="open").set(1)
                    CIRCUIT_STATE.labels(state="closed").set(0)

    def allow_request(self) -> bool:
        with self._lock:
            if self.state == self.CLOSED:
                return True
            if self.state == self.OPEN:
                if time.time() - self.opened_at >= self.timeout:
                    logger.info("Circuit breaker half-open — allowing trial request")
                    self.state = self.HALF_OPEN
                    CIRCUIT_STATE.labels(state="open").set(0)
                    CIRCUIT_STATE.labels(state="half_open").set(1)
                    return True
                return False
            if self.state == self.HALF_OPEN:
                return True
        return False

    @property
    def current_state(self):
        return self.state

circuit_breaker = CircuitBreaker(threshold=CIRCUIT_THRESHOLD, timeout=CIRCUIT_TIMEOUT)

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"]
)

REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Request latency in seconds",
    ["endpoint"],
    buckets=[0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0, 5.0]
)

CIRCUIT_STATE = Gauge(
    "circuit_breaker_state",
    "Circuit breaker state (1 = active)",
    ["state"]
)
CIRCUIT_STATE.labels(state="closed").set(1)
CIRCUIT_STATE.labels(state="open").set(0)
CIRCUIT_STATE.labels(state="half_open").set(0)

APP_INFO = Gauge(
    "app_info", "Application metadata",
    ["version", "error_rate"]
)
APP_INFO.labels(version="1.0.0", error_rate=str(ERROR_RATE)).set(1)

DEPENDENCY_UP = Gauge("dependency_up", "Whether the simulated dependency is reachable")
DEPENDENCY_UP.set(1)

# Initialise label combinations
for status in ["success", "error", "rejected"]:
    REQUEST_COUNT.labels(method="GET", endpoint="/", status=status)

# ── Retry with exponential backoff ────────────────────────────────────────────
@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=1, max=4),
    retry=retry_if_exception_type(Exception),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def call_downstream_dependency():
    """
    Simulates calling a downstream dependency with retry + backoff.
    In production this would be an HTTP call or DB query.
    Retries up to 3 times: wait 1s, then 2s, then 4s.
    """
    global dependency_healthy
    if not dependency_healthy:
        raise ConnectionError("Dependency unavailable")
    return True

# ── App state ─────────────────────────────────────────────────────────────────
dependency_healthy = True

# ── Graceful shutdown via lifespan ────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Handles startup and graceful shutdown.
    On SIGTERM: stops accepting new requests, waits for in-flight to complete.
    This prevents dropped requests during Kubernetes rolling updates.
    """
    logger.info("Application starting up")
    yield
    # Shutdown — give in-flight requests time to complete
    logger.info("Application shutting down gracefully — draining in-flight requests")
    await asyncio.sleep(2)
    logger.info("Shutdown complete")

# ── FastAPI app ───────────────────────────────────────────────────────────────
app = FastAPI(title="Cloud Lab API", version="1.0.0", lifespan=lifespan)

# Instrument FastAPI with OpenTelemetry — adds trace context to every request
FastAPIInstrumentor.instrument_app(app)

# ── Main endpoint ─────────────────────────────────────────────────────────────
@app.get("/")
def root(request: Request):
    start = time.time()

    # Get current trace ID for correlation with logs
    span = trace.get_current_span()
    trace_id = format(span.get_span_context().trace_id, "032x") \
        if span.get_span_context().is_valid else "no-trace"

    # ── Circuit breaker check ─────────────────────────────────────────────────
    if not circuit_breaker.allow_request():
        REQUEST_COUNT.labels(method="GET", endpoint="/", status="rejected").inc()
        logger.warning("Request rejected by circuit breaker",
                       extra={"trace_id": trace_id, "circuit_state": circuit_breaker.current_state})
        return JSONResponse(
            status_code=503,
            content={
                "error": "Service temporarily unavailable",
                "reason": "circuit_breaker_open",
                "retry_after": CIRCUIT_TIMEOUT,
            }
        )

    # ── Simulate failure ──────────────────────────────────────────────────────
    if random.random() < ERROR_RATE:
        circuit_breaker.record_failure()
        REQUEST_COUNT.labels(method="GET", endpoint="/", status="error").inc()
        REQUEST_LATENCY.labels(endpoint="/").observe(time.time() - start)
        logger.warning("Simulated failure",
                       extra={"trace_id": trace_id, "endpoint": "/", "status": "error"})
        raise Exception("Simulated failure")

    # ── Call downstream dependency with retry ─────────────────────────────────
    try:
        call_downstream_dependency()
    except Exception as e:
        circuit_breaker.record_failure()
        REQUEST_COUNT.labels(method="GET", endpoint="/", status="error").inc()
        REQUEST_LATENCY.labels(endpoint="/").observe(time.time() - start)
        logger.error("Dependency call failed after retries",
                     extra={"trace_id": trace_id, "error": str(e)})
        return JSONResponse(status_code=503, content={"error": "Dependency unavailable"})

    # ── Success ───────────────────────────────────────────────────────────────
    time.sleep(LATENCY_SECONDS)
    duration = time.time() - start

    circuit_breaker.record_success()
    REQUEST_COUNT.labels(method="GET", endpoint="/", status="success").inc()
    REQUEST_LATENCY.labels(endpoint="/").observe(duration)

    logger.info("Request handled",
                extra={"trace_id": trace_id, "endpoint": "/",
                       "status": "success", "duration_ms": round(duration * 1000, 2)})

    return {
        "message": "Cloud Lab Running",
        "version": "1.0.0",
        "trace_id": trace_id,
        "circuit_breaker": circuit_breaker.current_state,
    }

# ── Health endpoints ──────────────────────────────────────────────────────────
@app.get("/health/live")
def liveness():
    """Liveness — is the process alive? Fails → container restarts."""
    return JSONResponse(status_code=200,
                        content={"status": "alive", "timestamp": time.time()})

@app.get("/health/ready")
def readiness():
    """Readiness — is the app ready to serve? Fails → removed from load balancer."""
    if not dependency_healthy:
        DEPENDENCY_UP.set(0)
        return JSONResponse(status_code=503,
                            content={"status": "not_ready",
                                     "reason": "dependency_unavailable",
                                     "timestamp": time.time()})
    if circuit_breaker.current_state == CircuitBreaker.OPEN:
        return JSONResponse(status_code=503,
                            content={"status": "not_ready",
                                     "reason": "circuit_breaker_open",
                                     "timestamp": time.time()})
    DEPENDENCY_UP.set(1)
    return JSONResponse(status_code=200,
                        content={"status": "ready",
                                 "dependency": "healthy",
                                 "circuit_breaker": circuit_breaker.current_state,
                                 "timestamp": time.time()})

@app.get("/health/circuit")
def circuit_status():
    """Returns current circuit breaker state — useful for demos."""
    return JSONResponse(status_code=200,
                        content={
                            "state": circuit_breaker.current_state,
                            "error_count": circuit_breaker.error_count,
                            "total_count": circuit_breaker.total_count,
                            "threshold": circuit_breaker.threshold,
                            "timeout_seconds": circuit_breaker.timeout,
                        })

@app.get("/health/dependency/break")
def break_dependency():
    """Lab only — simulates a dependency going down."""
    global dependency_healthy
    dependency_healthy = False
    DEPENDENCY_UP.set(0)
    logger.warning("Dependency marked as unhealthy (lab simulation)")
    return {"status": "dependency marked down"}

@app.get("/health/dependency/restore")
def restore_dependency():
    """Lab only — restores the simulated dependency."""
    global dependency_healthy
    dependency_healthy = True
    DEPENDENCY_UP.set(1)
    logger.info("Dependency restored")
    return {"status": "dependency restored"}

# ── Metrics endpoint ──────────────────────────────────────────────────────────
@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type="text/plain")
