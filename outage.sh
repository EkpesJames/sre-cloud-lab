#!/bin/bash

echo "Simulating application outage..."

docker stop cloud-app

echo " Wait ~15 seconds..."
echo "Then check:"
echo "- Prometheus: http://localhost:9090/targets"
echo "- Alerts: http://localhost:9090/alerts"
echo "- Slack / Email for notifications"

