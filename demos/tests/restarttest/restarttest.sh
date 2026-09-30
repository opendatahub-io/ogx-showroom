#!/bin/bash

set -euo pipefail

# Configuration
NAMESPACE="redhat-ods-applications"
POD_LABEL="app=ogx"
MAX_WAIT_SECONDS=300
POLL_INTERVAL=5

# Check if uv is available
if ! command -v uv &> /dev/null; then
  echo "ERROR: uv is required to run tests (see Prerequisites in README.md)"
  exit 1
fi

# Check if oc is available and logged in
if ! command -v oc &> /dev/null; then
  echo "ERROR: oc CLI is required for restart tests"
  echo "Install: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html"
  exit 1
fi

# Verify oc is logged in and can access the cluster
if ! oc whoami &> /dev/null; then
  echo "ERROR: Not logged in to OpenShift cluster"
  echo "Please run: oc login <cluster-url>"
  exit 1
fi

# Verify we can access the target namespace
if ! oc get namespace "${NAMESPACE}" &> /dev/null; then
  echo "ERROR: Cannot access namespace '${NAMESPACE}'"
  echo "Current context: $(oc project -q 2>/dev/null || echo 'none')"
  exit 1
fi

echo "=========================================="
echo "Running persistence tests with restart..."
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RESPONSE_ID_FILE="${SCRIPT_DIR}/temp_response_id.txt"
VECTOR_ID_FILE="${SCRIPT_DIR}/temp_vector_store_id.txt"

# Clean up any previous test data
rm -f "${RESPONSE_ID_FILE}" "${VECTOR_ID_FILE}"

echo "=========================================="
echo "Step 1: Running initial conversation..."
echo "=========================================="
echo ""

uv run "${PROJECT_ROOT}/demos/responses/demo.py" --save-id "${RESPONSE_ID_FILE}"

if [ ! -f "${RESPONSE_ID_FILE}" ]; then
  echo "ERROR: Response ID file not created at ${RESPONSE_ID_FILE}"
  exit 1
fi

SAVED_RESPONSE_ID=$(cat "${RESPONSE_ID_FILE}")
echo ""
echo "Saved response ID: ${SAVED_RESPONSE_ID}"

echo ""
echo "=========================================="
echo "Step 1b: Creating vector store + chunks..."
echo "=========================================="
echo ""

uv run "${SCRIPT_DIR}/vectorcheck.py" create "${VECTOR_ID_FILE}"

if [ ! -f "${VECTOR_ID_FILE}" ]; then
  echo "ERROR: Vector store ID file not created at ${VECTOR_ID_FILE}"
  exit 1
fi

SAVED_VECTOR_ID=$(cat "${VECTOR_ID_FILE}")
echo ""
echo "Saved vector store ID: ${SAVED_VECTOR_ID}"

echo ""
echo "=========================================="
echo "Step 2: Restarting OGX pod..."
echo "=========================================="
echo ""

# Delete the ogx pod to trigger restart
POD_NAME=$(oc get pod -l "${POD_LABEL}" -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD_NAME" ]; then
  echo "ERROR: Could not find ogx pod"
  exit 1
fi

echo "Deleting pod: ${POD_NAME}"
oc delete pod "${POD_NAME}" -n "${NAMESPACE}"

# Wait for new pod to be ready
echo "Waiting for new pod to be ready..."
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT_SECONDS ]; do
  POD_STATUS=$(oc get pod -l "${POD_LABEL}" -n "${NAMESPACE}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  POD_READY=$(oc get pod -l "${POD_LABEL}" -n "${NAMESPACE}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

  if [ "$POD_STATUS" = "Running" ] && [ "$POD_READY" = "True" ]; then
    echo "Pod is ready"
    break
  fi

  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT_SECONDS ]; then
  echo "ERROR: Timeout waiting for pod to be ready"
  exit 1
fi

echo ""
echo "=========================================="
echo "Step 3: Retrieving and continuing conversation..."
echo "=========================================="
echo ""

uv run "${PROJECT_ROOT}/demos/responses/demo.py" --load-id "${RESPONSE_ID_FILE}"

echo ""
echo "=========================================="
echo "Step 3b: Querying vector store after restart..."
echo "=========================================="
echo ""

uv run "${SCRIPT_DIR}/vectorcheck.py" verify "${VECTOR_ID_FILE}"

echo ""
echo "=========================================="
echo "✓ Persistence test completed successfully"
echo "=========================================="
echo ""
echo "Verified:"
echo "  ✓ Response ID persisted across restart: ${SAVED_RESPONSE_ID}"
echo "  ✓ Conversation retrieved from database"
echo "  ✓ Conversation continued from saved state"
echo "  ✓ Vector store queryable after restart: ${SAVED_VECTOR_ID}"
echo ""

# Clean up
rm -f "${RESPONSE_ID_FILE}" "${VECTOR_ID_FILE}"
