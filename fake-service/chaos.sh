#!/bin/bash
# chaos.sh — Game Day scenario triggers
# Usage: ./chaos.sh [scenario]
#
# Scenarios:
#   error-burst     → floods /simulate with 500s (CFR alert should fire)
#   latency-spike   → forces slow requests (latency SLO burn alert)
#   normal          → sends clean traffic

FAKE_SERVICE="http://localhost:8080"

case "$1" in

  error-burst)
    echo "🔴 Triggering error burst — sending 60 x 500 errors over 60 seconds..."
    for i in $(seq 1 60); do
      curl -s -X POST "$FAKE_SERVICE/simulate" \
        -H "Content-Type: application/json" \
        -d '{"force_error": true, "endpoint": "/api/checkout"}' > /dev/null
      echo "  [$i/60] Error injected"
      sleep 1
    done
    echo "✅ Done. Watch #DevOps-Alerts for CFR alert."
    ;;

  latency-spike)
    echo "🟡 Triggering latency spike — sending slow requests for 5 minutes..."
    # Force repeated hits on /api/checkout which has high latency in error path
    for i in $(seq 1 300); do
      curl -s -X POST "$FAKE_SERVICE/simulate" \
        -H "Content-Type: application/json" \
        -d '{"force_error": false, "endpoint": "/api/checkout"}' > /dev/null
      sleep 1
    done
    echo "✅ Done. Check the latency SLO burn rate panel."
    ;;

  normal)
    echo "🟢 Sending clean traffic for 2 minutes..."
    for i in $(seq 1 120); do
      curl -s "$FAKE_SERVICE/health" > /dev/null
      sleep 1
    done
    echo "✅ Done."
    ;;

  check)
    echo "📊 Current fake-service health:"
    curl -s "$FAKE_SERVICE/health" | python3 -m json.tool
    echo ""
    echo "📊 Metrics endpoint (first 20 lines):"
    curl -s "$FAKE_SERVICE/metrics" | head -20
    ;;

  *)
    echo "Usage: $0 [error-burst|latency-spike|normal|check]"
    exit 1
    ;;
esac
