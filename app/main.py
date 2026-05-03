from fastapi import FastAPI
from fastapi.responses import Response
from prometheus_client import Counter, generate_latest

app = FastAPI()

REQUESTS = Counter("app_requests_total", "Total requests")

@app.get("/")
def root():
    REQUESTS.inc()
    return {"status": "running"}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type="text/plain")
