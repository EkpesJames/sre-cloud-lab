#!/bin/bash

echo "Stopping Cloud Lab Environment (preserving data)..."

docker rm -f cloud-app prometheus alertmanager grafana 2>/dev/null

echo "Removing network..."
docker network rm cloud-lab-net 2>/dev/null

echo "Environment stopped (data preserved)"
