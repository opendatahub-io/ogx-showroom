#!/bin/bash

set -euo pipefail

echo "=========================================="
echo "Provisioning with Helm..."
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="redhat-ods-applications"
VALUES_FILE="${SCRIPT_DIR}/values-local.yaml"

# Check prerequisites
if ! command -v helm &> /dev/null; then
  echo "ERROR: helm is required (brew install helm or dnf install helm)"
  exit 1
fi

if ! oc whoami &> /dev/null; then
  echo "ERROR: not logged in to OpenShift (run oc login first)"
  exit 1
fi

if [ ! -f "${VALUES_FILE}" ]; then
  echo "ERROR: ${VALUES_FILE} not found"
  echo "Create it with your vLLM credentials:"
  echo ""
  echo "  cat > values-local.yaml <<EOF"
  echo "  ogx:"
  echo "    inference:"
  echo '      vllmUrl: "https://your-vllm-inference-endpoint/v1"'
  echo '      vllmApiToken: "your-inference-token"'
  echo "    embedding:"
  echo '      vllmUrl: "https://your-vllm-embedding-endpoint/v1"'
  echo '      vllmApiToken: "your-embedding-token"'
  echo "  EOF"
  exit 1
fi

# Step 1: RHOAI CRs (managed by oc apply, not Helm)
echo "Applying DSCInitialization and DataScienceCluster..."
oc apply -f "${SCRIPT_DIR}/manifests/dscinitialization.yaml"
oc apply -f "${SCRIPT_DIR}/manifests/datasciencecluster.yaml"

echo "Waiting for DataScienceCluster to be ready..."
oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/default-dsc --timeout=600s

echo ""

# Step 2: Infrastructure
echo "Checking Helm release status..."
helm status ogx-infra -n "${NAMESPACE}" 2>&1 | head -5 || echo "  No existing ogx-infra release"

echo "Installing ogx-infra..."
helm upgrade --install ogx-infra "${SCRIPT_DIR}/charts/ogx-infra" \
  -n "${NAMESPACE}" --create-namespace --wait --timeout 10m

echo ""
echo "Infrastructure ready."
echo ""

# Step 3: OGX
echo "Checking Helm release status..."
helm status ogx-rhoai -n "${NAMESPACE}" 2>&1 | head -5 || echo "  No existing ogx-rhoai release"

echo "Installing ogx-rhoai..."
helm upgrade --install ogx-rhoai "${SCRIPT_DIR}/charts/ogx-rhoai" \
  -n "${NAMESPACE}" -f "${VALUES_FILE}" --wait --timeout 15m

echo ""
echo "Current OGXServer status:"
oc get ogxserver/ogx-distribution -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "  not found"
echo ""
echo "Pod status:"
oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null || echo "  No pods found"
echo ""

echo "Waiting for OGXServer to be ready..."
oc wait --for=jsonpath='{.status.phase}'=Ready ogxserver/ogx-distribution \
  -n "${NAMESPACE}" --timeout=600s

echo ""
echo "=========================================="
echo "Provisioning complete!"
echo "=========================================="
echo ""
echo "Run tests:  ./test.sh"
