#!/bin/bash

echo "Starting Cloud Lab Environment..."

# Create network if it doesn't exist
if ! docker network inspect cloud-lab-net >/dev/null 2>&1; then
  echo "Creating network..."
  docker network create cloud-lab-net
fi

# Build app image
echo "Building app image..."
docker build -t cloud-lab -f docker/Dockerfile .

# Start cloud app
echo "Starting cloud-app..."
docker rm -f cloud-app >/dev/null 2>&1
docker run -d \
  --name cloud-app \
  --network cloud-lab-net \
  -p 8080:80 \
  cloud-lab

# Start Prometheus
echo "Starting Prometheus..."
docker rm -f prometheus >/dev/null 2>&1
docker run -d \
  --name prometheus \
  --network cloud-lab-net \
  -p 9090:9090 \
  -v "$(pwd)/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml" \
  -v "$(pwd)/monitoring/alerts.yml:/etc/prometheus/alerts.yml" \
  prom/prometheus

# Start Alertmanager
echo "Starting Alertmanager..."
docker rm -f alertmanager >/dev/null 2>&1
docker run -d \
  --name alertmanager \
  --network cloud-lab-net \
  -p 9093:9093 \
  -v "$(pwd)/monitoring/alertmanager.yml:/etc/alertmanager/alertmanager.yml" \
  prom/alertmanager

# Start Grafana
echo "Starting Grafana..."
if ! docker volume inspect grafana-data >/dev/null 2>&1; then
  docker volume create grafana-data
fi

docker rm -f grafana >/dev/null 2>&1
docker run -d \
  --name grafana \
  --network cloud-lab-net \
  -p 3000:3000 \
  -v grafana-data:/var/lib/grafana \
  grafana/grafana

echo ""
echo "✅ Environment started!"
echo "App:          http://localhost:8080"
echo "Prometheus:   http://localhost:9090"
echo "Alertmanager: http://localhost:9093"
echo "Grafana:      http://localhost:3000"
