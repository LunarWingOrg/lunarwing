#!/usr/bin/env bash
set -euo pipefail

# Load test: 10 concurrent OCR requests
# Usage: ./load_test.sh <image-file>

IMAGE_FILE="${1:-}"
ENDPOINT="${OCR_ENDPOINT:-http://127.0.0.1:8088}"
CONCURRENT=10

if [[ -z "$IMAGE_FILE" ]]; then
    echo "Usage: $0 <image-file>"
    exit 1
fi

if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "Error: File not found: $IMAGE_FILE"
    exit 1
fi

B64=$(base64 -w 0 "$IMAGE_FILE")
PAYLOAD=$(jq -n --arg image "$B64" '{image: $image}')

AUTH_HEADER=""
if [[ -n "${LUNARWING_AUTH_TOKEN:-}" ]]; then
    AUTH_HEADER="Authorization: Bearer $LUNARWING_AUTH_TOKEN"
fi

echo "Running $CONCURRENT concurrent requests to $ENDPOINT/ocr..."

START_TIME=$(date +%s%N)

for i in $(seq 1 $CONCURRENT); do
    if [[ -n "$AUTH_HEADER" ]]; then
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -H "$AUTH_HEADER" \
            -d "$PAYLOAD" \
            "$ENDPOINT/ocr" > /dev/null &
    else
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" \
            "$ENDPOINT/ocr" > /dev/null &
    fi
done

wait

END_TIME=$(date +%s%N)
ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))

echo "Completed $CONCURRENT requests in ${ELAPSED_MS}ms"
echo "Average: $(( ELAPSED_MS / CONCURRENT ))ms per request"
