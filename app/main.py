from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, Gauge, generate_latest
import time
import random
import os
import json
import logging
import sys

# ── Structured logging setup ──────────────────────────────────────────────────
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
ERROR_RATE = float(os.getenv("APP_ERROR_RATE", "0.30"))
LATENCY_SECONDS = float(os.getenv("APP_LATENCY_SECONDS", "0.2"))

# ── App state ─────────────────────────────────────────────────────────────────
# Simulates a dependency (e.g. a database) being reachable
dependency_healthy = True

app = FastAPI(title="Cloud Lab API", version="1.0.0")

# ── Metrics ───────────────────────────────────────────────────────────────────
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

APP_INFO = Gauge(
    "app_info",
    "Application metadata",
    ["version", "error_rate"]
)
APP_INFO.labels(version="1.0.0", error_rate=str(ERROR_RATE)).set(1)

DEPENDENCY_UP = Gauge(
    "dependency_up",
    "Whether the simulated dependency is reachable (1=up, 0=down)"
)
DEPENDENCY_UP.set(1)

# Initialise label combinations so they appear in /metrics before traffic hits
for status in ["success", "error"]:
    REQUEST_COUNT.labels(method="GET", endpoint="/", status=status)

# ── Main endpoint ─────────────────────────────────────────────────────────────
@app.get("/")
def root():
    start = time.time()

    if random.random() < ERROR_RATE:
        REQUEST_COUNT.labels(method="GET", endpoint="/", status="error").inc()
        REQUEST_LATENCY.labels(endpoint="/").observe(time.time() - start)
        logger.warning("Simulated failure", extra={
            "endpoint": "/", "status": "error", "error_rate": ERROR_RATE
        })
        raise Exception("Simulated failure")

    time.sleep(LATENCY_SECONDS)
    duration = time.time() - start

    REQUEST_COUNT.labels(method="GET", endpoint="/", status="success").inc()
    REQUEST_LATENCY.labels(endpoint="/").observe(duration)

    logger.info("Request handled", extra={
        "endpoint": "/", "status": "success", "duration_ms": round(duration * 1000, 2)
    })

    return {"message": "Cloud Lab Running", "version": "1.0.0"}

# ── Health endpoints ───────────────────────────────────────────────────────────

@app.get("/health/live")
def liveness():
    """
    Liveness probe — is the process alive and able to handle requests?
    Returns 200 as long as the app is running.
    In Kubernetes, a failed liveness check causes the container to restart.
    """
    return JSONResponse(
        status_code=200,
        content={"status": "alive", "timestamp": time.time()}
    )

@app.get("/health/ready")
def readiness():
    """
    Readiness probe — is the app ready to serve traffic?
    Checks that dependencies (e.g. database) are reachable.
    Returns 503 if not ready — load balancer will stop sending traffic.
    In Kubernetes, a failed readiness check removes the pod from the service endpoint.
    """
    if not dependency_healthy:
        logger.warning("Readiness check failed — dependency unhealthy")
        DEPENDENCY_UP.set(0)
        return JSONResponse(
            status_code=503,
            content={
                "status": "not_ready",
                "reason": "dependency_unavailable",
                "timestamp": time.time()
            }
        )

    DEPENDENCY_UP.set(1)
    return JSONResponse(
        status_code=200,
        content={
            "status": "ready",
            "dependency": "healthy",
            "timestamp": time.time()
        }
    )

@app.get("/health/dependency/break")
def break_dependency():
    """Lab-only endpoint — simulates a dependency going down."""
    global dependency_healthy
    dependency_healthy = False
    logger.warning("Dependency marked as unhealthy (lab simulation)")
    return {"status": "dependency marked down — /health/ready will return 503"}

@app.get("/health/dependency/restore")
def restore_dependency():
    """Lab-only endpoint — restores the simulated dependency."""
    global dependency_healthy
    dependency_healthy = True
    logger.info("Dependency restored")
    return {"status": "dependency restored — /health/ready will return 200"}

# ── Metrics endpoint ───────────────────────────────────────────────────────────
@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type="text/plain")
