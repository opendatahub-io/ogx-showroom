#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_file="${PRAXIS_MVP_WORKLOAD_FILE:-$script_dir/artifacts/workload.env}"
images_file="${PRAXIS_MVP_IMAGES_FILE:-$script_dir/artifacts/images.env}"
timeout="${PRAXIS_MVP_TIMEOUT_SECONDS:-300}"
for command in oc curl jq; do command -v "$command" >/dev/null || { printf 'ERROR: %s is required\n' "$command" >&2; exit 1; }; done
[[ -f "$state_file" && -f "$images_file" ]] || { printf 'ERROR: create the workload first\n' >&2; exit 1; }
# shellcheck disable=SC1090
source "$state_file"
# shellcheck disable=SC1090
source "$images_file"
: "${MODEL_NAME:?workload file is missing MODEL_NAME}"
: "${PROVIDER_MODEL:?workload file is missing PROVIDER_MODEL}"

wait_for() {
  local description="$1" command="$2" deadline=$((SECONDS + timeout))
  until eval "$command" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || { printf 'ERROR: timed out waiting for %s\n' "$description" >&2; exit 1; }
    sleep 2
  done
}

wait_for 'ExternalProvider' "test \"\$(oc get externalprovider praxis-mvp-provider-a -n '$TENANT_NAMESPACE' -o jsonpath='{.status.phase}')\" = Ready"
wait_for 'ExternalModel' "test \"\$(oc get externalmodel praxis-mvp-demo -n '$TENANT_NAMESPACE' -o jsonpath='{.status.phase}')\" = Ready"
# The standalone praxis-ai hop was removed from the dataplane. The cluster carries
# several payload-processing Deployments; the Praxis one for this workload is
# payload-processing-external-model, rendered into the tenant namespace once the
# MaaSTenantConfig is switched to praxis. The payload-processing and
# payload-pre-processing Deployments in the Gateway namespace are not part of this path.
wait_for 'payload-processing-external-model' "oc get deployment payload-processing-external-model -n '$TENANT_NAMESPACE' -o json | jq -e '.status.availableReplicas == 1'"
wait_for 'MaaSSubscription' "test \"\$(oc get maassubscription praxis-mvp -n '$TENANT_NAMESPACE' -o jsonpath='{.status.phase}')\" = Active"

host="$(oc get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.status.addresses[0].value}')"
[[ -n "$host" ]] || { printf 'ERROR: Gateway has no address\n' >&2; exit 1; }
tmp_dir="$(mktemp -d)"
key_id=""
cleanup_key() {
  if [[ -n "$key_id" && -s "$tmp_dir/admin-header" ]]; then
    curl -ksS --max-time 30 -o /dev/null -X DELETE -H @"$tmp_dir/admin-header" "https://$host/v1/api-keys/$key_id" || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup_key EXIT
chmod 700 "$tmp_dir"
printf 'Authorization: Bearer %s\n' "$(oc whoami -t)" >"$tmp_dir/admin-header"
chmod 600 "$tmp_dir/admin-header"
status="$(curl -ksS --max-time 30 -o "$tmp_dir/key.json" -w '%{http_code}' -X POST \
  -H @"$tmp_dir/admin-header" -H 'Content-Type: application/json' \
  --data '{"name":"praxis-mvp","subscription":"praxis-mvp"}' "https://$host/v1/api-keys")"
[[ "$status" == 201 ]] || { printf 'ERROR: API-key creation returned HTTP %s\n' "$status" >&2; exit 1; }
key="$(jq -er .key "$tmp_dir/key.json")"
key_id="$(jq -er .id "$tmp_dir/key.json")"
printf 'Authorization: Bearer %s\n' "$key" >"$tmp_dir/key-header"
chmod 600 "$tmp_dir/key-header"
rm -f "$tmp_dir/key.json"

url="https://$host/$TENANT_NAMESPACE/$MODEL_NAME/v1/chat/completions"
body="{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: LiteMaaS reachable\"}],\"max_tokens\":32}"
request() {
  curl -ksS --max-time 60 -o "$tmp_dir/response.json" -w '%{http_code}' \
    -H @"$tmp_dir/key-header" -H 'Content-Type: application/json' --data "$body" "$url"
}

status="$(request)"
[[ "$status" == 200 ]] || { printf 'ERROR: gateway request returned HTTP %s\n' "$status" >&2; exit 1; }
cat "$tmp_dir/response.json"
jq -e --arg model "$PROVIDER_MODEL" '.model | contains($model)' "$tmp_dir/response.json" >/dev/null || { printf 'ERROR: response did not use the LiteMaaS Qwen model\n' >&2; exit 1; }

missing_status="$(curl -ksS --max-time 30 -o /dev/null -w '%{http_code}' -H @"$tmp_dir/key-header" \
  -H 'Content-Type: application/json' --data '{"model":"missing","messages":[]}' \
  "https://$host/$TENANT_NAMESPACE/missing/v1/chat/completions")"
[[ "$missing_status" == 404 ]] || { printf 'ERROR: unknown model returned HTTP %s, expected 404\n' "$missing_status" >&2; exit 1; }

if [[ -n "$OGX_UID" ]]; then
  [[ "$(oc get ogxserver ogx-distribution -n "$APPLICATIONS_NAMESPACE" -o jsonpath='{.metadata.uid}')" == "$OGX_UID" ]] || { printf 'ERROR: pre-existing OGX changed\n' >&2; exit 1; }
  [[ "$(oc get deployment ogx-distribution -n "$APPLICATIONS_NAMESPACE" -o jsonpath='{.status.availableReplicas}')" == 1 ]] || { printf 'ERROR: pre-existing OGX is not available\n' >&2; exit 1; }
  if [[ -n "${OGX_POD_UID:-}" ]]; then
    [[ "$(oc get pod -n "$APPLICATIONS_NAMESPACE" -l app=ogx -o jsonpath='{.items[0].metadata.uid}')" == "$OGX_POD_UID" ]] || { printf 'ERROR: pre-existing OGX pod was replaced\n' >&2; exit 1; }
  fi
fi
printf 'PASS: ExternalModel routed through Praxis to LiteMaaS and OGX was preserved.\n'
