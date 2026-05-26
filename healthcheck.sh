#!/bin/bash
set -euo pipefail

# Health check and smoke test for deployed vLLM instances
# Usage: ./healthcheck.sh <ALB_DNS_NAME>

ALB_DNS="${1:-}"

if [[ -z "$ALB_DNS" ]]; then
    # Try to get from terraform
    if [[ -d terraform ]]; then
        ALB_DNS=$(cd terraform && terraform output -raw alb_dns_name 2>/dev/null || echo "")
    fi
    if [[ -z "$ALB_DNS" ]]; then
        echo "Usage: ./healthcheck.sh <ALB_DNS_NAME>"
        echo "   or: cd terraform && terraform output alb_dns_name"
        exit 1
    fi
fi

BASE_URL="http://${ALB_DNS}"

echo "=== vLLM Health Check ==="
echo "Endpoint: $BASE_URL"
echo ""

# 1. Basic health
echo -n "Health endpoint... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health" --max-time 10 || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
    echo "OK (200)"
else
    echo "FAILED (HTTP $HTTP_CODE)"
    exit 1
fi

# 2. Model info
echo -n "Models endpoint... "
MODELS=$(curl -s "${BASE_URL}/v1/models" --max-time 10)
MODEL_ID=$(echo "$MODELS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "UNKNOWN")
echo "OK (model: $MODEL_ID)"

# 3. Inference smoke test
echo -n "Inference test... "
START=$(date +%s%N)
RESPONSE=$(curl -s "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    --max-time 30 \
    -d '{
        "model": "'"$MODEL_ID"'",
        "messages": [{"role": "user", "content": "Say hello in one word."}],
        "max_tokens": 10
    }')
END=$(date +%s%N)
LATENCY_MS=$(( (END - START) / 1000000 ))

CONTENT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "")
if [[ -n "$CONTENT" ]]; then
    echo "OK (${LATENCY_MS}ms, response: \"$CONTENT\")"
else
    echo "FAILED"
    echo "$RESPONSE"
    exit 1
fi

# 4. Metrics endpoint
echo -n "Metrics endpoint... "
METRICS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/metrics" --max-time 10 || echo "000")
if [[ "$METRICS_CODE" == "200" ]]; then
    echo "OK (Prometheus metrics available)"
else
    echo "WARNING (HTTP $METRICS_CODE - metrics may not be exposed through ALB)"
fi

echo ""
echo "=== All Checks Passed ==="
echo "API Base URL: ${BASE_URL}/v1"
