#!/bin/bash

# Simple health check script
while true; do
    echo "HTTP/1.1 200 OK" | nc -l -p 8080 -q 1
    echo "Content-Type: text/plain"
    echo ""
    echo "kafka-gitops is running"
    sleep 1
done