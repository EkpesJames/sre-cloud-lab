from fastapi import FastAPI
from fastapi.responses import Response
from prometheus_client import Counter, Histogram, generate_latest
import time
import random

app = FastAPI()

# --- METRICS ---

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["status"]
)

REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Request latency",
    buckets=[0.1, 0.3, 0.5, 1, 2, 5]
)

# Initialize labels so both appear even before traffic
REQUEST_COUNT.labels(status="success")
REQUEST_COUNT.labels(status="error")


# --- APP ENDPOINT ---

@app.get("/")
def root():
    # Simulate random failures (30%)
    if random.random() < 0.3:
        REQUEST_COUNT.labels(status="error").inc()
        raise Exception("Simulated failure")

    REQUEST_COUNT.labels(status="success").inc()

    with REQUEST_LATENCY.time():
        time.sleep(0.2)  # small delay for latency metric
        return {"message": "Cloud Lab Running"}


# --- METRICS ENDPOINT ---

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type="text/plain")
