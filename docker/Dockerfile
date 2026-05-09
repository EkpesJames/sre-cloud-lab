FROM python:3.11-slim

WORKDIR /app

COPY app/ /app

RUN pip install -r requirements.txt

# Health check — Docker marks container unhealthy if this fails 3 times
# Interval: check every 10 seconds
# Timeout: fail if no response within 5 seconds
# Retries: 3 failures = unhealthy
# Start period: give the app 10 seconds to start before checking
HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=10s \
  CMD curl -f http://localhost/health/live || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "80"]
