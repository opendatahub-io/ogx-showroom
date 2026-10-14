#!/usr/bin/env bash
set +x
set -euo pipefail

if [[ "${1:-}" == --help ]]; then
  cat <<'EOF'
Usage: ./praxis_mode/build-deploy.sh [ai-gateway-controller|maas-controller|praxis-extproc]

Clone missing repositories into praxis_mode/src, build with Podman, push to Quay,
and install a Pod-only Kyverno image override. Replace affected Deployment pods
and verify their new image and readiness. Existing checkouts are never updated.

Defaults: component=ai-gateway-controller, IMAGE_REPO=quay.io/higginsd/imagehost,
VERSION=<commit>[-dirty]-<UTC timestamp>, TENANT_NAME=praxis-demo, WAIT_TIMEOUT=600
(seconds). SOURCE_DIR overrides the selected repository path. Requires Podman
registry login, cluster-admin, and an existing Kyverno installation.
PRAXIS_FEATURES optionally overrides Containerfile CARGO_FEATURES for ExtProc only;
unset preserves the source defaults. It does not enable APIs on an AITenant.
Temporary ExtProc builds include the sibling praxis-ai checkout (including local
edits). PRAXIS_AI_SOURCE_DIR overrides that path; no sources are updated.

MaaS uses models-as-a-service/maas-controller/Dockerfile, not the API image.
MaaS builds patch only the installed AITenant Responses schema from that source.
They set opendatahub.io/managed=false on that CRD to stop operator reconciliation,
including future packaged schema upgrades. Other schema fields and RBAC are
unchanged. This opt-out affects all tenants and remains until explicitly removed.
EOF
  exit 0
fi

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $# -le 1 ]] || fail 'Use --help for usage'
COMPONENT=${1:-ai-gateway-controller}
case "$COMPONENT" in
  ai-gateway-controller) REPO=ai-gateway-controller; PREFIX=ai-g-c; DOCKERFILE=Dockerfile; PACKAGED=odh-ai-gateway-controller-rhel9 ;;
  maas-controller) REPO=models-as-a-service; PREFIX=maas-c; DOCKERFILE=maas-controller/Dockerfile; PACKAGED=odh-maas-controller-rhel9 ;;
  praxis-extproc) REPO=praxis-extproc; PREFIX=praxis-extproc; DOCKERFILE=Containerfile; PACKAGED=odh-praxis-extproc-rhel9 ;;
  *) fail "Unknown component: $COMPONENT" ;;
esac
BUILD_ARGS=()
if [[ -n ${PRAXIS_FEATURES:-} ]]; then
  [[ "$COMPONENT" == praxis-extproc ]] || fail 'PRAXIS_FEATURES is only supported for praxis-extproc'
  [[ "$PRAXIS_FEATURES" =~ ^[a-zA-Z0-9_/-]+(,[a-zA-Z0-9_/-]+)*$ ]] || fail 'PRAXIS_FEATURES must be a comma-separated Cargo feature list'
  BUILD_ARGS+=(--build-arg "CARGO_FEATURES=$PRAXIS_FEATURES")
fi
for tool in git podman oc jq tar find chmod; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=${SOURCE_DIR:-$SCRIPT_DIR/src/$REPO}
if [[ "$COMPONENT" == praxis-extproc ]]; then
  PRAXIS_AI_SOURCE_DIR=${PRAXIS_AI_SOURCE_DIR:-$(dirname "$SOURCE_DIR")/praxis-ai}
  [[ -f "$PRAXIS_AI_SOURCE_DIR/Cargo.toml" ]] || fail "Missing local Praxis AI workspace: $PRAXIS_AI_SOURCE_DIR"
fi
IMAGE_REPO=${IMAGE_REPO:-quay.io/higginsd/imagehost}
TENANT_NAME=${TENANT_NAME:-praxis-demo}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-600}
[[ "$WAIT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail 'WAIT_TIMEOUT must be a positive number of seconds'
CONTEXT=$(oc config current-context)
OC=(oc --context "$CONTEXT" --request-timeout=30s)
OWNER=ogx-showroom-praxis-build
POLICY=replace-rhoai-praxis-$COMPONENT
PATTERN="^(registry\\.redhat\\.io|quay\\.io)/rhoai/$PACKAGED(:|@|$)"

"${OC[@]}" whoami >/dev/null
"${OC[@]}" get crd clusterpolicies.kyverno.io >/dev/null
"${OC[@]}" wait deployment/kyverno-admission-controller -n kyverno --for=condition=Available --timeout="${WAIT_TIMEOUT}s"
APP_NS=$("${OC[@]}" get dscinitializations.dscinitialization.opendatahub.io -o json | jq -er '.items | select(length == 1) | .[0].spec.applicationsNamespace')
NAMESPACES=$(jq -nc --arg ns "$APP_NS" '[$ns]')
INSTANCES='[]'
if [[ "$COMPONENT" == praxis-extproc ]]; then
  [[ "$TENANT_NAME" != models-as-a-service ]] || fail 'Use a separate demo tenant'
  AITENANT_NS=$("${OC[@]}" get deployment maas-controller -n "$APP_NS" -o json | jq -er '.spec.template.spec.containers[].env[] | select(.name == "AITENANT_NAMESPACE") | .value')
  TENANT=$("${OC[@]}" get aitenants.maas.opendatahub.io "$TENANT_NAME" -n "$AITENANT_NS" -o json)
  NAMESPACES=$(jq -ec '[.status.gatewayRef.namespace, .status.tenantNamespace] | unique | select(all(.[]; type == "string" and length > 0))' <<<"$TENANT")
  INSTANCES=$(jq -nc --arg tenant "$TENANT_NAME" '["payload-processing", "payload-pre-processing", "payload-processing-external-model"] | map(.+"-"+$tenant)')
  POLICY=$POLICY-$TENANT_NAME
fi
EXISTING=$("${OC[@]}" get clusterpolicy "$POLICY" --ignore-not-found -o json)
[[ -z "$EXISTING" ]] || jq -e --arg owner "$OWNER" '.metadata.labels["app.kubernetes.io/managed-by"] == $owner' <<<"$EXISTING" >/dev/null || fail "Refusing to overwrite policy $POLICY"
ARCH=$("${OC[@]}" get nodes -o json | jq -er '[.items[].status.nodeInfo.architecture] | unique | select(length == 1) | .[0]')
echo "Building $COMPONENT for linux/$ARCH; cluster context: $CONTEXT"

if [[ ! -e "$SOURCE_DIR" ]]; then
  mkdir -p "$(dirname "$SOURCE_DIR")"
  git clone "https://github.com/opendatahub-io/$REPO.git" "$SOURCE_DIR"
fi
[[ -d "$SOURCE_DIR/.git" || -f "$SOURCE_DIR/.git" ]] || fail "Not a Git checkout: $SOURCE_DIR"
[[ -f "$SOURCE_DIR/$DOCKERFILE" ]] || fail "Missing $SOURCE_DIR/$DOCKERFILE"
COMMIT=$(git -C "$SOURCE_DIR" rev-parse --short=12 HEAD)
DIRTY=
[[ -z $(git -C "$SOURCE_DIR" status --porcelain) ]] || DIRTY=-dirty
VERSION=${VERSION:-$COMMIT$DIRTY-$(date -u +%Y%m%dT%H%M%SZ)}
TAG=$PREFIX-$VERSION
[[ "$TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ && ${#TAG} -le 128 ]] || fail "Invalid image tag: $TAG"
IMAGE=$IMAGE_REPO:$TAG

# Vendor manifests in a disposable copy, not over local source edits.
WORK=$(mktemp -d /tmp/opencode/praxis-build.XXXXXXXX)
cleanup_build() {
  local status=$?
  trap - EXIT
  # Copied test assets can have read-only directories; never change the source.
  if ! find "$WORK" -type d -exec chmod u+w {} + || ! rm -rf -- "$WORK"; then
    echo "WARNING: Build cleanup incomplete: $WORK" >&2
  fi
  exit "$status"
}
trap cleanup_build EXIT
mkdir "$WORK/context"
tar -C "$SOURCE_DIR" --exclude=./.git --exclude=./target --exclude=./bin --exclude=./maas-controller/bin -cf - . | tar -C "$WORK/context" -xf -
if [[ "$COMPONENT" == praxis-extproc ]]; then
  echo "Including local Praxis AI: $PRAXIS_AI_SOURCE_DIR"
  tar -C "$PRAXIS_AI_SOURCE_DIR" --exclude=./.git --exclude=./target -cf "$WORK/context/praxis-ai.tar" .
fi
if [[ "$COMPONENT" == ai-gateway-controller && ! -f "$WORK/context/config/manifests/praxis-extproc/overlays/odh/kustomization.yaml" ]]; then
  command -v make >/dev/null || fail 'make is required to vendor controller manifests'
  command -v yq >/dev/null || fail 'Mike Farah yq v4 is required to vendor controller manifests'
  TMPDIR=/tmp/opencode make -C "$WORK/context" get-manifests
fi

patch_responses_schema() {
  local mode=$1 live patch
  live=$("${OC[@]}" get crd aitenants.maas.opendatahub.io -o json)
  # Opt out and patch atomically, guarded against CRD recreation or concurrent edits.
  patch=$(jq -n --slurpfile source "$WORK/aitenant-crd.json" --argjson live "$live" '
    [$live.spec.versions | to_entries[] | select(.value.served or .value.storage) |
      . as $version |
      [$source[0].spec.versions[] | select(.name == $version.value.name) |
        .schema.openAPIV3Schema.properties.spec.properties.responses] |
      if length != 1 or .[0].type != "object" or .[0].properties.enabled.type != "boolean"
      then error("source lacks Responses schema for installed version " + $version.value.name)
      else .[0] end as $responses |
      if $version.value.schema.openAPIV3Schema.properties.spec.properties.responses == $responses
      then empty else {op:"add",
        path:("/spec/versions/" + ($version.key | tostring) + "/schema/openAPIV3Schema/properties/spec/properties/responses"),
        value:$responses} end
    ] as $schemaChanges |
    (if $live.metadata.annotations["opendatahub.io/managed"] == "false" then []
     elif $live.metadata.annotations == null then
       [{op:"add",path:"/metadata/annotations",value:{"opendatahub.io/managed":"false"}}]
     else [{op:"add",path:"/metadata/annotations/opendatahub.io~1managed",value:"false"}]
     end) + $schemaChanges as $changes |
    if ($changes | length) == 0 then [] else
      [{op:"test",path:"/metadata/uid",value:$live.metadata.uid},
       {op:"test",path:"/metadata/resourceVersion",value:$live.metadata.resourceVersion}] + $changes
    end')
  if [[ "$patch" == '[]' ]]; then
    echo 'AITenant operator opt-out and Responses schema match the build source.'
    return
  fi
  [[ "$mode" != verify ]] || fail 'AITenant operator opt-out or Responses schema changed during rollout; image override remains installed. Check platform operator reconciliation.'
  "${OC[@]}" patch crd aitenants.maas.opendatahub.io --type=json --patch "$patch" --dry-run=server >/dev/null
  if [[ "$mode" == apply ]]; then
    echo 'Disabling operator updates to the shared AITenant CRD and patching Responses schema; other schema fields and RBAC are unchanged.'
    "${OC[@]}" patch crd aitenants.maas.opendatahub.io --type=json --patch "$patch"
  fi
}

if [[ "$COMPONENT" == maas-controller ]]; then
  AITENANT_CRD="$WORK/context/deployment/base/maas-controller/crd/bases/maas.opendatahub.io_aitenants.yaml"
  [[ -f "$AITENANT_CRD" ]] || fail "Missing $AITENANT_CRD"
  "${OC[@]}" create --dry-run=client --validate=false -f "$AITENANT_CRD" -o json > "$WORK/aitenant-crd.json"
  jq -e '.apiVersion == "apiextensions.k8s.io/v1" and .kind == "CustomResourceDefinition" and
    .metadata.name == "aitenants.maas.opendatahub.io"' "$WORK/aitenant-crd.json" >/dev/null || fail 'Source is not the AITenant CRD'
  patch_responses_schema check
fi
podman build --platform "linux/$ARCH" --build-arg "VERSION=$VERSION" "${BUILD_ARGS[@]}" -f "$WORK/context/$DOCKERFILE" -t "$IMAGE" "$WORK/context"
podman push --digestfile "$WORK/digest" "$IMAGE"
DIGEST=$(cat "$WORK/digest")
[[ "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || fail 'Push did not return a valid image digest'
PULL_IMAGE=$IMAGE_REPO@$DIGEST

if [[ "$COMPONENT" == maas-controller ]]; then
  patch_responses_schema apply
fi

jq -n --arg policy "$POLICY" --arg owner "$OWNER" --arg image "$PULL_IMAGE" --arg pattern "$PATTERN" --argjson namespaces "$NAMESPACES" --argjson instances "$INSTANCES" '
  {apiVersion:"kyverno.io/v1",kind:"ClusterPolicy",
   metadata:{name:$policy,labels:{"app.kubernetes.io/managed-by":$owner},annotations:{"pod-policies.kyverno.io/autogen-controllers":"none"}},
   spec:{background:false,failurePolicy:"Ignore",rules:[{
     name:"replace-image",match:{any:[{resources:({kinds:["Pod"],namespaces:$namespaces,operations:["CREATE"]} +
       if ($instances | length) > 0 then {selector:{matchExpressions:[{key:"maas.opendatahub.io/tenant-instance",operator:"In",values:$instances}]}} else {} end)}]},
     mutate:{foreach:["containers","initContainers"] | map(. as $field | {
       list:("request.object.spec."+$field+" || `[]`"),
       preconditions:{all:[{key:("{{ regex_match('\''"+$pattern+"'\'', '\''{{element.image}}'\'') }}"),operator:"Equals",value:true}]},
       patchStrategicMerge:{spec:{($field):[{name:"{{ element.name }}",image:$image}]}}
     })}
   }]}}' | "${OC[@]}" apply --server-side --field-manager="$OWNER" -f -
"${OC[@]}" wait clusterpolicy/"$POLICY" --for=condition=Ready --timeout="${WAIT_TIMEOUT}s"

deployment_pods() {
  local namespace=$1 uid=$2 replicasets
  replicasets=$("${OC[@]}" get replicasets -n "$namespace" -o json | jq -c --arg uid "$uid" '[.items[] | select(any(.metadata.ownerReferences[]?; .uid == $uid)) | .metadata.uid]')
  "${OC[@]}" get pods -n "$namespace" -o json | jq -c --argjson rs "$replicasets" '[.items[] | select(any(.metadata.ownerReferences[]?; .uid as $uid | $rs | index($uid))) | select(.metadata.deletionTimestamp == null)]'
}

COUNT=0
while IFS= read -r namespace; do
  DEPLOYMENTS=$("${OC[@]}" get deployments -n "$namespace" -o json | jq -c --arg pattern "$PATTERN" --argjson instances "$INSTANCES" '.items[] |
    select(($instances | length) == 0 or (.spec.template.metadata.labels["maas.opendatahub.io/tenant-instance"] as $instance | $instances | index($instance))) |
    select(any((.spec.template.spec.containers + (.spec.template.spec.initContainers // []))[]; .image | test($pattern)))')
  while IFS= read -r deployment; do
    [[ -n "$deployment" ]] || continue
    name=$(jq -r '.metadata.name' <<<"$deployment")
    uid=$(jq -r '.metadata.uid' <<<"$deployment")
    replicas=$(jq -r '.spec.replicas // 1' <<<"$deployment")
    [[ "$replicas" -gt 0 ]] || { echo "Skipping scaled-down Deployment $namespace/$name"; continue; }
    targets=$(jq -c --arg pattern "$PATTERN" '[.spec.template.spec | .containers[], .initContainers[]? | select(.image | test($pattern)) | .name]' <<<"$deployment")
    # Check admission on the real template before deleting any running pod.
    probe=$(jq --arg name "praxis-image-check-$PREFIX" --arg ns "$namespace" '{apiVersion:"v1",kind:"Pod",metadata:(.spec.template.metadata + {name:$name,namespace:$ns}),spec:.spec.template.spec}' <<<"$deployment" | "${OC[@]}" create --dry-run=server -f - -o json)
    jq -e --arg image "$PULL_IMAGE" --argjson targets "$targets" '[(.spec.containers + (.spec.initContainers // []))[] | select(.name as $name | $targets | index($name))] | length == ($targets | length) and all(.[]; .image == $image)' <<<"$probe" >/dev/null || fail "Policy did not replace the image for $namespace/$name; no pods deleted"
    pods=$(deployment_pods "$namespace" "$uid")
    mapfile -t pod_names < <(jq -r '.[].metadata.name' <<<"$pods")
    echo "Replacing pods for $namespace/$name with $PULL_IMAGE"
    if [[ ${#pod_names[@]} -gt 0 ]]; then
      "${OC[@]}" delete pod -n "$namespace" "${pod_names[@]}" --timeout="${WAIT_TIMEOUT}s"
    fi
    deadline=$((SECONDS + WAIT_TIMEOUT))
    while true; do
      pods=$(deployment_pods "$namespace" "$uid")
      if jq -e --arg image "$PULL_IMAGE" --argjson replicas "$replicas" --argjson targets "$targets" '
        length >= $replicas and all(.[];
          any(.status.conditions[]?; .type == "Ready" and .status == "True") and
          ([(.spec.containers + (.spec.initContainers // []))[] | select(.name as $name | $targets | index($name))] |
            length == ($targets | length) and all(.[]; .image == $image)))' <<<"$pods" >/dev/null; then
        break
      fi
      if (( SECONDS >= deadline )); then
        jq '[.[] | {name:.metadata.name,images:[.spec.containers[].image],status:.status.phase}]' <<<"$pods" >&2
        fail "Timed out waiting for $namespace/$name; policy remains installed"
      fi
      sleep 3
    done
    COUNT=$((COUNT + 1))
    echo "Ready: $namespace/$name"
  done <<<"$DEPLOYMENTS"
done < <(jq -r '.[]' <<<"$NAMESPACES")

if [[ "$COMPONENT" == maas-controller ]]; then
  patch_responses_schema verify
fi
echo "Pushed: $IMAGE"
echo "Policy: $POLICY -> $PULL_IMAGE; verified $COUNT Deployment(s)"
[[ "$COUNT" -gt 0 ]] || echo 'No running matching Deployments found; the policy applies to future pods.'
echo 'No other CRD schema fields or RBAC changed; no inference request was made.'
