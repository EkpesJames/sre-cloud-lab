#!/bin/bash

echo "FULL RESET — removing EVERYTHING..."

# Stop & remove containers
docker rm -f cloud-app prometheus alertmanager grafana 2>/dev/null

# Remove network
docker network rm cloud-lab-net 2>/dev/null

# Remove volumes (eletes Grafana dashboards)
docker volume rm grafana-data 2>/dev/null

# Clean unused resources
docker system prune -f

echo "Full reset complete"
