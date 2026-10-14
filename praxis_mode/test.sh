#!/usr/bin/env bash
set +x
set -euo pipefail

# Requires a ready demo with Responses enabled. Sends three paid requests.
TENANT_NAME=${TENANT_NAME:-praxis-demo}
TENANT_NS="ai-tenant-$TENANT_NAME"
GW_NS=openshift-ingress
TEST_PORT=${TEST_PORT:-18443}
OC=(oc --context "$(oc config current-context)" --request-timeout=30s)
MODEL=$("${OC[@]}" get externalmodels.inference.opendatahub.io openai-model -n "$TENANT_NS" -o jsonpath='{.spec.modelName}')
HOST=$("${OC[@]}" get gateway "$TENANT_NAME-gateway" -n "$GW_NS" -o jsonpath='{.status.addresses[0].value}')
URL="https://$HOST"
ADMIN=$("${OC[@]}" whoami -t)
STATE=$(mktemp -d "${TMPDIR:-/tmp/opencode}/praxis-demo.XXXXXX")
KEY_ID=""
KEY=""
RESPONSE_IDS=()
CONVERSATION_ID=""
PF_PID=""
CURL=(--silent --show-error --fail-with-body --noproxy '*' --connect-timeout 5 --max-time 60
      --cacert "$STATE/ca.crt" --connect-to "$HOST:443:127.0.0.1:$TEST_PORT")

cleanup() {
  local rc=$?
  for response_id in "${RESPONSE_IDS[@]}"; do
    curl "${CURL[@]}" -H "Authorization: Bearer $KEY" \
      -X DELETE "$URL/v1/responses/$response_id" >/dev/null || rc=1
  done
  if [[ -n "$CONVERSATION_ID" ]]; then
    curl "${CURL[@]}" -H "Authorization: Bearer $KEY" \
      -X DELETE "$URL/v1/conversations/$CONVERSATION_ID" >/dev/null || rc=1
  fi
  if [[ -n "$KEY_ID" ]]; then
    curl "${CURL[@]}" -H "Authorization: Bearer $ADMIN" \
      -X DELETE "$URL/v1/api-keys/$KEY_ID" >/dev/null || rc=1
  fi
  [[ -z "$PF_PID" ]] || { kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; }
  rm -f "$STATE/ca.crt" "$STATE/port-forward.log"
  rmdir "$STATE"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"${OC[@]}" get configmap openshift-service-ca.crt -n "$GW_NS" -o jsonpath='{.data.service-ca\.crt}' >"$STATE/ca.crt"
"${OC[@]}" port-forward -n "$GW_NS" "svc/${HOST%%.*}" "$TEST_PORT:443" >"$STATE/port-forward.log" 2>&1 &
PF_PID=$!
for _ in {1..30}; do
  grep -q 'Forwarding from' "$STATE/port-forward.log" && break
  sleep 1
done
grep -q 'Forwarding from' "$STATE/port-forward.log"

# Create a temporary MaaS key; cleanup revokes it on exit.
KEY_JSON=$(curl "${CURL[@]}" -H "Authorization: Bearer $ADMIN" \
  -H 'Content-Type: application/json' "$URL/v1/api-keys" \
  -d '{"name":"praxis-demo-test","subscription":"praxis-demo","ephemeral":true}')
KEY_ID=$(jq -er '.id' <<<"$KEY_JSON")
KEY=$(jq -er '.key' <<<"$KEY_JSON")
unset KEY_JSON

echo 'Chat Completions:'
curl "${CURL[@]}" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  "$URL/$TENANT_NS/$MODEL/v1/chat/completions" \
  -d "$(jq -nc --arg model "$MODEL" '{model:$model,messages:[{role:"user",content:"Say hello."}]}')" | jq .

RESPONSE_CODE="praxis-response-$RANDOM-$RANDOM"
FOLLOW_UP='What code did I ask you to remember? Reply only with that code.'

echo 'Responses chain, turn 1:'
RESPONSE=$(curl "${CURL[@]}" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  "$URL/v1/responses" \
  -d "$(jq -nc --arg model "$MODEL" --arg input "Remember this code: $RESPONSE_CODE. Reply only OK." \
    '{model:$model,input:$input,store:true,stream:false,max_output_tokens:256}')") || {
  printf '%s\n' "$RESPONSE" >&2
  exit 1
}
RESPONSE_ID=$(jq -er '.id' <<<"$RESPONSE")
RESPONSE_IDS+=("$RESPONSE_ID")
jq . <<<"$RESPONSE"
jq -e '.status == "completed"' <<<"$RESPONSE" >/dev/null

echo 'Responses chain, turn 2 (previous_response_id):'
RESPONSE=$(curl "${CURL[@]}" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  "$URL/v1/responses" \
  -d "$(jq -nc --arg model "$MODEL" --arg previous "$RESPONSE_ID" --arg input "$FOLLOW_UP" \
    '{model:$model,input:$input,previous_response_id:$previous,store:true,stream:false,max_output_tokens:256}')") || {
  printf '%s\n' "$RESPONSE" >&2
  exit 1
}
RESPONSE_ID=$(jq -er '.id' <<<"$RESPONSE")
RESPONSE_IDS+=("$RESPONSE_ID")
jq . <<<"$RESPONSE"
jq -e --arg code "$RESPONSE_CODE" --arg previous "${RESPONSE_IDS[0]}" '
  .status == "completed" and .previous_response_id == $previous and
  any(.output[]?.content[]?; .type == "output_text" and (.text | contains($code)))
' <<<"$RESPONSE" >/dev/null

for response_id in "${RESPONSE_IDS[@]}"; do
  echo "Responses retrieve: $response_id"
  curl "${CURL[@]}" -H "Authorization: Bearer $KEY" "$URL/v1/responses/$response_id" | jq .
  echo "Responses input-items: $response_id"
  curl "${CURL[@]}" -H "Authorization: Bearer $KEY" "$URL/v1/responses/$response_id/input_items" | jq .
done

echo 'Conversations create:'
CONVERSATION=$(curl "${CURL[@]}" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  "$URL/v1/conversations" -d '{}')
CONVERSATION_ID=$(jq -er '.id' <<<"$CONVERSATION")
jq . <<<"$CONVERSATION"
jq -e '.object == "conversation"' <<<"$CONVERSATION" >/dev/null

for index in "${!RESPONSE_IDS[@]}"; do
  echo "Responses delete: ${RESPONSE_IDS[index]}"
  curl "${CURL[@]}" -H "Authorization: Bearer $KEY" -X DELETE "$URL/v1/responses/${RESPONSE_IDS[index]}" | jq .
  unset 'RESPONSE_IDS[index]'
done

echo 'Chat Completions, Responses chain and Conversation creation passed.'
