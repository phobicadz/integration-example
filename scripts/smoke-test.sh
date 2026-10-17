#!/usr/bin/env bash
# =============================================================================
# End-to-end smoke test for the ProductIntegration durable-functions app.
#
#   Usage:  scripts/smoke-test.sh <base-url> [correlation-id]
#           scripts/smoke-test.sh https://localhost:7071
#           scripts/smoke-test.sh https://prodint-fn-xxxx.azurewebsites.net "my-run-42"
#
# What it proves (in order):
#   1. POST /api/products/import returns 202 and echoes x-correlation-id back
#      (both as a response header and in the JSON body)  -> the id is honoured
#   2. the status endpoint reaches a terminal state        -> orchestration + DTS work
#   3. the finished run still reports the SAME correlationId, in the status body
#      and in the output summary                           -> the id survived the run
#   4. Posted + Skipped + Rejected + Failed == TotalFetched  -> no items are lost
#
# It deliberately does NOT assert exact counts: the first run on a fresh instance
# posts everything, a repeat run on the same warm instance is suppressed by the
# version guard (posted 0 / skipped N). Both are correct behaviour.
# =============================================================================
set -euo pipefail

BASE_URL="${1:?usage: smoke-test.sh <https://host> [correlation-id]}"
CORRELATION_ID="${2:-smoke-$(date -u +%Y%m%d%H%M%S)}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
POLL_MAX_ATTEMPTS="${POLL_MAX_ATTEMPTS:-40}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v curl >/dev/null || fail "curl is required"
command -v jq  >/dev/null || fail "jq is required"

echo "== 1. start a run (correlation id: $CORRELATION_ID)"
code=$(curl -sS \
        -o "$TMP/start.json" -D "$TMP/headers.txt" \
        -w '%{http_code}' \
        -X POST "$BASE_URL/api/products/import" \
        -H 'content-type: application/json' \
        -H "x-correlation-id: $CORRELATION_ID" \
        -d '{}')
[ "$code" = "202" ] || { cat "$TMP/start.json"; fail "expected 202 Accepted, got $code"; }

HEADER_ID=$(tr -d '\r' < "$TMP/headers.txt" \
             | awk 'tolower($1)=="x-correlation-id:"{ sub(/^[^:]*:[ ]*/,""); print; exit }')
[ "$HEADER_ID" = "$CORRELATION_ID" ] \
  || fail "the response did not echo x-correlation-id back (got '$HEADER_ID')"

RUN_ID=$(jq -r '.runId' "$TMP/start.json")
STATUS_URL=$(jq -r '.statusUrl' "$TMP/start.json")
RETURNED_ID=$(jq -r '.correlationId' "$TMP/start.json")
[ "$RETURNED_ID" = "$CORRELATION_ID" ] \
  || fail "body correlationId mismatch: got '$RETURNED_ID'"

echo "   runId=$RUN_ID"
echo "   status=$BASE_URL$STATUS_URL"

echo "== 2. poll the status endpoint until the run finishes"
STATE=""
for attempt in $(seq 1 "$POLL_MAX_ATTEMPTS"); do
  sleep "$POLL_INTERVAL_SECONDS"
  curl -sS -o "$TMP/status.json" "$BASE_URL$STATUS_URL"
  STATE=$(jq -r '.runtimeStatus // "Unknown"' "$TMP/status.json")
  echo "   attempt $attempt: $STATE"
  if [ "$STATE" != "Running" ] && [ "$STATE" != "Pending" ] && [ "$STATE" != "Unknown" ]; then
    break
  fi
done

if [ "$STATE" != "Completed" ]; then
  echo "--- failure details ---"
  jq '.failure' "$TMP/status.json" || true
  fail "run ended in state '$STATE'"
fi

echo "== 3. the correlation id survived the whole run"
STATUS_ID=$(jq -r '.correlationId' "$TMP/status.json")
[ "$STATUS_ID" = "$CORRELATION_ID" ] \
  || fail "status response lost the correlation id (got '$STATUS_ID')"
SUMMARY_ID=$(jq -r '.output.correlationId // ""' "$TMP/status.json")
[ "$SUMMARY_ID" = "$CORRELATION_ID" ] \
  || fail "run summary lost the correlation id (got '$SUMMARY_ID')"
echo "   status body + output summary both report $CORRELATION_ID"

echo "== 4. summary invariant"
jq '{runId, correlationId, runtimeStatus, totalFetched: .output.totalFetched,
     posted: .output.posted, skipped: .output.skipped,
     rejected: .output.rejected, failed: .output.failed}' "$TMP/status.json"

BALANCED=$(jq '(.output.posted + .output.skipped + .output.rejected + .output.failed)
               == .output.totalFetched' "$TMP/status.json")
[ "$BALANCED" = "true" ] || fail "posted+skipped+rejected+failed != totalFetched"

echo
echo "OK: smoke test passed against $BASE_URL (run $RUN_ID, correlation $CORRELATION_ID)"
