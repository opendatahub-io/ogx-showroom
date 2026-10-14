#!/usr/bin/env bash
set +x
set -euo pipefail

FULL=false
case "${1:-}" in
  '') ;;
  --full) FULL=true ;;
  --help)
    cat <<'EOF'
Usage: bash praxis_mode/cleanup.sh [--full]

Remove the Praxis demo resources, AITenant and dedicated Gateway.
--full also removes owned MaaS PostgreSQL and its PVC.
Shared Responses PostgreSQL, certificates and platform bindings are never removed.
Owned MaaS database data is permanently lost. Refuses detected foreign consumers.

Keeps shared RHCL/Authorino, AI Gateway/MaaS enablement, image overrides,
CRDs, and namespaces. Unrelated resources and OGX are not modified.
Requires cluster-admin and interactive confirmation. No finalizers are forced.
Overrides: TENANT_NAME (praxis-demo), WAIT_TIMEOUT (600s).
EOF
    exit 0 ;;
  *) echo 'Use --help for usage.' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo 'Use --help for usage.' >&2; exit 2; }
TENANT_NAME=${TENANT_NAME:-praxis-demo}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-600s}
OWNER=ogx-showroom-praxis
fail() { echo "ERROR: $*" >&2; exit 1; }
for tool in oc jq; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done
[[ "$TENANT_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#TENANT_NAME} -le 30 ]] || fail 'TENANT_NAME must be a DNS label of at most 30 characters'
[[ "$TENANT_NAME" != models-as-a-service ]] || fail 'Cannot remove the shared default tenant'
CONTEXT=$(oc config current-context)
OC=(oc --context "$CONTEXT" --request-timeout=30s)
APP_NS=$("${OC[@]}" get dscinitializations.dscinitialization.opendatahub.io -o json | jq -er '.items | select(length == 1) | .[0].spec.applicationsNamespace')
MANAGER=$("${OC[@]}" get deployment maas-controller -n "$APP_NS" -o json)
GW_NS=$(jq -er '.spec.template.spec.containers[].env[] | select(.name == "GATEWAY_NAMESPACE") | .value' <<<"$MANAGER")
AITENANT_NS=$(jq -er '.spec.template.spec.containers[].env[] | select(.name == "AITENANT_NAMESPACE") | .value' <<<"$MANAGER")
INFRA_NS=$(jq -er '.spec.template.spec.containers[].env[] | select(.name == "INFRA_NAMESPACE") | .value' <<<"$MANAGER")
GATEWAY="$TENANT_NAME-gateway"
TENANT=$("${OC[@]}" get aitenants.maas.opendatahub.io "$TENANT_NAME" -n "$AITENANT_NS" --ignore-not-found -o json)
[[ -n "$TENANT" ]] || TENANT='{}'
TENANT_NS=$(jq -r --arg fallback "ai-tenant-$TENANT_NAME" '.status.tenantNamespace // $fallback' <<<"$TENANT")
[[ "$TENANT_NS" == "ai-tenant-$TENANT_NAME" ]] || fail "Unexpected tenant namespace: $TENANT_NS"

check_owner() {
  local resource=$1 name=$2 namespace=$3 existing
  existing=$("${OC[@]}" get "$resource" "$name" -n "$namespace" --ignore-not-found -o json)
  [[ -z "$existing" ]] || jq -e --arg owner "$OWNER" \
    '.metadata.labels["app.kubernetes.io/managed-by"] == $owner' <<<"$existing" >/dev/null || \
    fail "Refusing to delete foreign resource $namespace/$resource/$name"
}
delete_owned() {
  local resource=$1 name=$2 namespace=$3
  check_owner "$resource" "$name" "$namespace"
  "${OC[@]}" delete "$resource" "$name" -n "$namespace" --ignore-not-found --cascade=foreground --wait=true --timeout="$WAIT_TIMEOUT"
}
check_database_consumers() {
  local workloads
  workloads=$("${OC[@]}" get deployments,replicasets,statefulsets,daemonsets,jobs,cronjobs,pods -n "$INFRA_NS" -o json)
  # Generated Jobs and Pods can lack tenant labels; follow their owner UIDs.
  jq -e --arg tenant "$TENANT_NAME" --arg owner "$OWNER" '
    def demo_owned($items; $depth):
      (.metadata.labels["maas.opendatahub.io/tenant-name"] == $tenant) or
      (.kind == "Deployment" and .metadata.name == "maas-postgres" and
       .metadata.labels["app.kubernetes.io/managed-by"] == $owner) or
      ($depth > 0 and any(.metadata.ownerReferences[]?;
        .uid as $uid | any($items[];
          .metadata.uid == $uid and demo_owned($items; $depth - 1))));
    .items as $items |
    [$items[] | select(
      (.metadata.labels["app.kubernetes.io/name"] == "maas-api" or
       (.spec | tostring | test("maas-db-config|maas-postgres"))) and
      (demo_owned($items; 4) | not)
    )] | length == 0' <<<"$workloads" >/dev/null || fail 'Other workloads may use the MaaS database; use cleanup without --full'
}

# Preflight everything before deleting anything.
[[ "$TENANT_NS" != "$INFRA_NS" ]] || fail 'Tenant namespace must not be the shared infrastructure namespace'
check_owner aitenants.maas.opendatahub.io "$TENANT_NAME" "$AITENANT_NS"
check_owner networkpolicy "$TENANT_NAME-maas-db-egress" "$INFRA_NS"
for resource in role rolebinding; do
  check_owner "$resource" "$TENANT_NAME-model-finalizer" "$TENANT_NS"
done
for item in "gateway/$GATEWAY" "configmap/$GATEWAY-config" "envoyfilters.networking.istio.io/$GATEWAY-authorino-tls"; do
  check_owner "${item%%/*}" "${item#*/}" "$GW_NS"
done
DB_RESOURCES=(deployment/maas-postgres service/maas-postgres pvc/maas-postgres-data secret/maas-postgres-credentials secret/maas-db-config)
if "$FULL"; then
  for item in "${DB_RESOURCES[@]}"; do
    check_owner "${item%%/*}" "${item#*/}" "$INFRA_NS"
  done
  check_database_consumers
fi
echo "Context: $CONTEXT"
echo "Delete demo resources in $TENANT_NS, AITenant $AITENANT_NS/$TENANT_NAME and Gateway $GW_NS/$GATEWAY."
if "$FULL"; then
  echo "Also permanently delete the owned MaaS database and PVC in $INFRA_NS."
fi
echo 'Shared Responses storage/bindings, platform, namespaces and image overrides will remain.'
read -r -p "Type $TENANT_NAME to confirm: " CONFIRM || fail 'Confirmation required'
[[ "$CONFIRM" == "$TENANT_NAME" ]] || fail 'Cleanup cancelled'

# Remove demo models while their controllers and the tenant are still available.
for resource in maassubscriptions.maas.opendatahub.io maasauthpolicies.maas.opendatahub.io \
  maasmodelrefs.maas.opendatahub.io externalmodels.inference.opendatahub.io \
  externalproviders.inference.opendatahub.io secrets; do
  OBJECTS=$("${OC[@]}" get "$resource" -n "$TENANT_NS" -l "app.kubernetes.io/managed-by=$OWNER" -o json)
  while IFS= read -r name; do
    [[ -z "$name" ]] || delete_owned "$resource" "$name" "$TENANT_NS"
  done < <(jq -r '.items[].metadata.name' <<<"$OBJECTS")
done
# Keep the Gateway and database available until tenant finalizers complete.
delete_owned aitenants.maas.opendatahub.io "$TENANT_NAME" "$AITENANT_NS"
delete_owned networkpolicy "$TENANT_NAME-maas-db-egress" "$INFRA_NS"
for resource in rolebinding role; do
  delete_owned "$resource" "$TENANT_NAME-model-finalizer" "$TENANT_NS"
done
for item in "gateway/$GATEWAY" "envoyfilters.networking.istio.io/$GATEWAY-authorino-tls" "configmap/$GATEWAY-config"; do
  delete_owned "${item%%/*}" "${item#*/}" "$GW_NS"
done
if "$FULL"; then
  check_database_consumers
  for item in "${DB_RESOURCES[@]}"; do
    delete_owned "${item%%/*}" "${item#*/}" "$INFRA_NS"
  done
fi
echo 'Cleanup complete. Run ./praxis_mode/setup.sh to provision again.'
