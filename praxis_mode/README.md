# Praxis demo

Run Chat Completions, a stored two-turn Responses chain and Conversation creation
through a dedicated MaaS/Praxis Gateway, using OpenAI and separate PostgreSQL
storage. This is a development integration, not a packaged-product or FIPS claim.
See [STATUS.md](STATUS.md) for implementation contracts, PRs and validation limits.

## Prerequisites

- A disposable OpenShift cluster, a cluster-admin login and a ready RHOAI
  DataScienceCluster named `default-dsc`.
- RHOAI with packaged AI Gateway/MaaS and Praxis support, PostgreSQL 16 in its
  CSV related images, Gateway API, Istio and a source Gateway named
  `data-science-gateway` in `openshift-ingress`.
- A default StorageClass capable of provisioning two 1 GiB ReadWriteOnce PVCs.
- Kyverno with `kyverno-admission-controller` in namespace `kyverno`.
- Bash, `oc`, `jq`, `curl`, `gh`, OpenSSL and standard Linux utilities; Mike Farah
  `yq` v4 for extracting the schema below. Authenticate `gh` for repository reads.
- Pull access from the cluster to the recorded images in
  `quay.io/higginsd/imagehost` and the RHOAI/RHCL images.
- An OpenAI API key with access to a model supporting Chat Completions and
  Responses. The default is `gpt-6-luna`; set `OPENAI_MODEL` to an available model
  before setup if necessary. Inference costs money.

The root [setup guide](../README.md#setup-from-source) installs the showroom
platform; `../setup.sh` installs Kyverno v1.12.1 if absent. Its default catalog is
`quay.io/rhoai/rhoai-fbc-fragment:rhoai-3.6-ea.2`, channel `beta`. These are
configuration defaults, not a recorded tested version matrix. Exact tested
OpenShift, RHOAI and RHCL versions are not recorded. Do not assume arbitrary
operator versions are compatible. Reuse an existing showroom installation rather
than rerunning its shared-platform setup unnecessarily.

The instructions below use the default tenant and Gateway namespace because
`test.sh` assumes `openshift-ingress`. OGX is not used for these inference calls
and existing OGX resources are left unchanged.

## 1. Select the cluster and prepare storage

Run all commands from the repository root, in the same Bash session. Scripts use
the current kube context; they do not accept `--context`.

```bash
set +x
set -euo pipefail
oc config use-context YOUR_CONTEXT
oc whoami
oc config current-context
export TENANT_NAME=praxis-demo
mkdir -p /tmp/opencode

oc get datasciencecluster default-dsc
oc get gateway data-science-gateway -n openshift-ingress
oc get storageclass
oc wait deployment/kyverno-admission-controller -n kyverno \
  --for=condition=Available --timeout=600s

bash praxis_mode/setup.sh --provision-responses-storage

APP_NS=$(oc get dscinitializations.dscinitialization.opendatahub.io -o json | \
  jq -er '.items | select(length == 1) | .[0].spec.applicationsNamespace')
MANAGER=$(oc get deployment maas-controller -n "$APP_NS" -o json)
controller_env() {
  jq -er --arg name "$1" \
    '.spec.template.spec.containers[].env[] | select(.name == $name) | .value' <<<"$MANAGER"
}
AITENANT_NS=$(controller_env AITENANT_NAMESPACE)
INFRA_NS=$(controller_env INFRA_NAMESPACE)
GW_NS=$(controller_env GATEWAY_NAMESPACE)
[[ "$GW_NS" == openshift-ingress ]]
oc get secret responses-db-config responses-db-ca -n "$INFRA_NS"
AI_SA=$(oc get deployment ai-gateway-controller -n "$APP_NS" \
  -o jsonpath='{.spec.template.spec.serviceAccountName}')
MAAS_SA=$(jq -er '.spec.template.spec.serviceAccountName' <<<"$MANAGER")
WORK=$(mktemp -d /tmp/opencode/praxis-docs.XXXXXXXX)
```

Storage preparation enables packaged AI Gateway/MaaS and creates retained mTLS
Responses storage and split platform bindings. It does not create the demo tenant
or enable Responses. It refuses conflicting bindings or missing retained
credentials. The infrastructure namespace must exist when provisioning starts;
if it is still being created, wait for it and rerun the storage command.

## 2. Install the matching schema and supplemental RBAC

These operations affect the shared platform. The schema patch disables operator
management of the entire AITenant CRD, including future packaged schema updates.
It installs only the Responses field, not a replacement CRD.

```bash
MAAS_REV=25fec6eef989894b6aaf2802621e3d91718bf1a3
AI_REV=6643d37b6f8f0668d405f2019c9e89d6ff851985
gh api "repos/derekhiggins/models-as-a-service/contents/deployment/base/maas-controller/crd/bases/maas.opendatahub.io_aitenants.yaml?ref=$MAAS_REV" \
  --jq '.content' | base64 -d > "$WORK/aitenant.yaml"
yq -o=json '.' "$WORK/aitenant.yaml" > "$WORK/aitenant.json"
oc get crd aitenants.maas.opendatahub.io -o json > "$WORK/live.json"
jq -n --slurpfile source "$WORK/aitenant.json" --slurpfile live "$WORK/live.json" '
  $live[0] as $l |
  [{op:"test",path:"/metadata/uid",value:$l.metadata.uid},
   {op:"test",path:"/metadata/resourceVersion",value:$l.metadata.resourceVersion}] +
  (if $l.metadata.annotations == null then
     [{op:"add",path:"/metadata/annotations",value:{"opendatahub.io/managed":"false"}}]
   else [{op:"add",path:"/metadata/annotations/opendatahub.io~1managed",value:"false"}] end) +
  [$l.spec.versions | to_entries[] | select(.value.served or .value.storage) |
   . as $v |
   [$source[0].spec.versions[] | select(.name == $v.value.name) |
     .schema.openAPIV3Schema.properties.spec.properties.responses] |
   if length != 1 or .[0].properties.enabled.type != "boolean"
   then error("source lacks matching Responses schema") else .[0] end as $schema |
   {op:"add",path:("/spec/versions/"+($v.key|tostring)+"/schema/openAPIV3Schema/properties/spec/properties/responses"),value:$schema}]
' > "$WORK/schema-patch.json"
oc patch crd aitenants.maas.opendatahub.io --type=json \
  --patch-file "$WORK/schema-patch.json" --dry-run=server
oc patch crd aitenants.maas.opendatahub.io --type=json \
  --patch-file "$WORK/schema-patch.json"

gh api "repos/derekhiggins/ai-gateway-controller/contents/config/self/rbac/clusterrole.yaml?ref=$AI_REV" \
  --jq '.content' | base64 -d > "$WORK/controller-role.yaml"
yq '.metadata.name = "praxis-demo-ai-gateway-runtime"' "$WORK/controller-role.yaml" | \
  oc create -f -
oc create clusterrolebinding praxis-demo-ai-gateway-runtime \
  --clusterrole=praxis-demo-ai-gateway-runtime --serviceaccount="$APP_NS:$AI_SA"
oc create clusterrole praxis-demo-maas-inferenceobjectives-read \
  --verb=get,list,watch --resource=inferenceobjectives.llm-d.ai
oc create clusterrolebinding praxis-demo-maas-inferenceobjectives-read \
  --clusterrole=praxis-demo-maas-inferenceobjectives-read \
  --serviceaccount="$APP_NS:$MAAS_SA"
```

The supplemental AI Gateway role is the pinned controller's complete runtime
role, including cluster-wide Secret read/write and route management. This is a
development-platform privilege grant, not tenant isolation. It avoids editing
operator-owned roles. The MaaS grant supplies missing InferenceObjective reads.
If a named supplemental role/binding already exists, inspect it and its subjects
instead of overwriting it. Setup separately installs the tenant-local model
finalizer grant. Supplemental cluster roles/bindings are retained by cleanup.

## 3. Deploy the recorded controller images

Use the recorded images to avoid unpublished source-build changes. The digests
and their contents are documented in [STATUS.md](STATUS.md#sources-and-recorded-deployment).
Ensure the images support your nodes' architecture before proceeding.

The following function creates Pod-only image overrides, leaving operator-owned
Deployment image fields unchanged. Existing policies are not overwritten. On a
rerun, inspect an existing policy's digest and scope before deciding to reuse it.

```bash
AI_IMAGE=quay.io/higginsd/imagehost@sha256:d62ef788777d57c87eebce36f1fedf8da4c060920b943e9a6f4d7b5e154d7577
MAAS_IMAGE=quay.io/higginsd/imagehost@sha256:7285d8d6ef0742dd839331eb2b1e62a97873a8105ff4390c5c2743afbcc00325
EXTPROC_IMAGE=quay.io/higginsd/imagehost@sha256:9bedfadb93c9fd58ec5f07e4aaf9753c500f4e04ab3ef14975aad8b7aa9ec59a
image_policy() {
  local policy=$1 packaged=$2 image=$3 namespaces=$4 instances=${5:-[]}
  jq -n --arg policy "$policy" --arg packaged "$packaged" --arg image "$image" \
    --argjson namespaces "$namespaces" --argjson instances "$instances" '
    {apiVersion:"kyverno.io/v1",kind:"ClusterPolicy",
     metadata:{name:$policy,labels:{"app.kubernetes.io/managed-by":"ogx-showroom-praxis-build"},
       annotations:{"pod-policies.kyverno.io/autogen-controllers":"none"}},
     spec:{background:false,failurePolicy:"Ignore",rules:[{
       name:"replace-image",match:{any:[{resources:({kinds:["Pod"],namespaces:$namespaces,operations:["CREATE"]} +
         if ($instances|length)>0 then {selector:{matchExpressions:[{
           key:"maas.opendatahub.io/tenant-instance",operator:"In",values:$instances}]}} else {} end)}]},
       mutate:{foreach:["containers","initContainers"] | map(. as $field | {
         list:("request.object.spec."+$field+" || `[]`"),
         preconditions:{all:[{key:("{{ regex_match('\''^(registry\\.redhat\\.io|quay\\.io)/rhoai/"+$packaged+"(:|@|$)'\'', '\''{{element.image}}'\'') }}"),operator:"Equals",value:true}]},
         patchStrategicMerge:{spec:{($field):[{name:"{{ element.name }}",image:$image}]}}
       })}
     }]}}' | oc create -f -
  oc wait clusterpolicy/"$policy" --for=condition=Ready --timeout=600s
}
APP_NAMESPACES=$(jq -nc --arg ns "$APP_NS" '[$ns]')
image_policy replace-rhoai-praxis-ai-gateway-controller \
  odh-ai-gateway-controller-rhel9 "$AI_IMAGE" "$APP_NAMESPACES"
image_policy replace-rhoai-praxis-maas-controller \
  odh-maas-controller-rhel9 "$MAAS_IMAGE" "$APP_NAMESPACES"
```

Before each restart, check admission using the real Deployment template:

```bash
check_image() {
  local namespace=$1 deployment=$2 expected=$3
  oc get deployment "$deployment" -n "$namespace" -o json | \
    jq --arg ns "$namespace" '{apiVersion:"v1",kind:"Pod",
      metadata:(.spec.template.metadata + {name:"praxis-image-check",namespace:$ns}),
      spec:.spec.template.spec}' | oc create --dry-run=server -f - -o json | \
    jq -e --arg image "$expected" 'any(.spec.containers[]; .image == $image)'
}
check_image "$APP_NS" ai-gateway-controller "$AI_IMAGE"
check_image "$APP_NS" maas-controller "$MAAS_IMAGE"
oc rollout restart deployment/ai-gateway-controller deployment/maas-controller -n "$APP_NS"
oc rollout status deployment/ai-gateway-controller -n "$APP_NS" --timeout=600s
oc rollout status deployment/maas-controller -n "$APP_NS" --timeout=600s
oc get pods -n "$APP_NS" -o json | jq -r '.items[] |
  select(.metadata.name | test("^(ai-gateway-controller|maas-controller)-")) |
  [.metadata.name, (.spec.containers | map(.image) | join(",")), .status.phase] | @tsv'
```

Both controller replacements affect all tenants. Confirm running pods use the
recorded digests and are Ready, not merely that rollout commands succeeded.

## 4. Set up the tenant and deploy ExtProc

Load the provider credential without putting it in shell history:

```bash
read -rsp 'OpenAI API key: ' OPENAI_API_KEY
export OPENAI_API_KEY
# Optional: export OPENAI_MODEL=YOUR_AVAILABLE_MODEL
bash praxis_mode/setup.sh
unset OPENAI_API_KEY
TENANT_NS="ai-tenant-$TENANT_NAME"

EXT_NAMESPACES=$(jq -nc --arg gw "$GW_NS" --arg ns "$TENANT_NS" '[$gw,$ns] | unique')
EXT_INSTANCES=$(jq -nc --arg tenant "$TENANT_NAME" \
  '["payload-processing","payload-pre-processing","payload-processing-external-model"] | map(.+"-"+$tenant)')
image_policy "replace-rhoai-praxis-praxis-extproc-$TENANT_NAME" \
  odh-praxis-extproc-rhel9 "$EXTPROC_IMAGE" "$EXT_NAMESPACES" "$EXT_INSTANCES"
for entry in "$GW_NS/payload-pre-processing-$TENANT_NAME" \
  "$GW_NS/payload-processing-$TENANT_NAME" \
  "$TENANT_NS/payload-processing-external-model-$TENANT_NAME"; do
  namespace=${entry%%/*}
  deployment=${entry#*/}
  check_image "$namespace" "$deployment" "$EXTPROC_IMAGE"
  oc rollout restart deployment/"$deployment" -n "$namespace"
  oc rollout status deployment/"$deployment" -n "$namespace" --timeout=600s
done
```

Setup installs RHCL/Authorino if absent, creates/reuses MaaS API-key storage,
creates the dedicated Gateway and tenant, grants the current user access to the
model, and aligns model/MaaS route hostnames. It leaves Responses disabled.
ExtProc overrides are scoped to this tenant, including its Gateway-local pods.

## 5. Enable Responses and check readiness

```bash
oc patch aitenants.maas.opendatahub.io "$TENANT_NAME" -n "$AITENANT_NS" --type=merge \
  -p '{"spec":{"responses":{"enabled":true,"storage":{"mode":"PlatformDefault","deletionPolicy":"Retain"}}}}'
oc get aitenants.maas.opendatahub.io "$TENANT_NAME" -n "$AITENANT_NS" -o json | \
  jq -e '.spec.responses.enabled == true'
oc wait "httproute/responses-api-$TENANT_NAME" -n "$TENANT_NS" \
  --for=create --timeout=600s
oc wait "secret/responses-runtime-$TENANT_NAME" -n "$TENANT_NS" \
  --for=create --timeout=600s
oc wait "deployment/payload-processing-external-model-$TENANT_NAME" -n "$TENANT_NS" \
  --for=jsonpath='{.spec.template.spec.volumes[?(@.name=="responses-binding")].secret.secretName}'="responses-runtime-$TENANT_NAME" \
  --timeout=600s
oc rollout status "deployment/payload-processing-external-model-$TENANT_NAME" \
  -n "$TENANT_NS" --timeout=600s
oc get httproute "responses-api-$TENANT_NAME" -n "$TENANT_NS" -o json | \
  jq '{hostnames:.spec.hostnames,parents:.status.parents}'
oc get pods -n "$TENANT_NS" -o wide
oc get pods -n "$GW_NS" -l "maas.opendatahub.io/tenant-instance=payload-processing-$TENANT_NAME" -o wide
```

Confirm the Responses route uses the same hostname as the model and MaaS API
routes, and its parent conditions include `Accepted=True` and `ResolvedRefs=True`.
Confirm the ExternalModel pod is Ready and uses `EXTPROC_IMAGE`, including its
init container. AITenant `Ready` alone does not qualify Responses readiness.
Do not configure `retention.maxAge`; it is not implemented. Storage initialization
failures also block this tenant's ExternalModel chat path.

## 6. Run the demo

Only run this step when you approve three paid OpenAI requests:

```bash
bash praxis_mode/test.sh
```

The current cluster-admin token authenticates MaaS key creation. The script
creates a temporary MaaS key, port-forwards the Gateway on localhost port 18443
with service-CA verification, then runs:

1. Chat Completions.
2. A stored non-streaming Response containing a random code.
3. A linked Response that recalls the code using `previous_response_id`.
4. Retrieval and original input-items for both Responses.
5. Conversation creation and local record deletion.

Success ends with `Chat Completions, Responses chain and Conversation creation passed.`
The script revokes its key, deletes its Conversation/Responses and removes its
port-forward and temporary files on exit. Set `TEST_PORT` if 18443 is occupied.
It does not qualify Conversation-backed inference, SSE persistence, database
restart durability or comprehensive security. Local deletion does not establish
upstream OpenAI deletion.

For failures, inspect controller logs, ExtProc logs and HTTPRoute parent
conditions before rerunning paid tests. `Forbidden` errors usually require
checking the discovered service accounts and supplemental RBAC. A missing
Responses field after patching indicates an incompatible or reconciled CRD.
An ExtProc init/readiness failure requires checking binding/key permissions and
PostgreSQL mTLS, without printing Secret values.

## Source builds

`build-deploy.sh` builds and deploys local checkouts; it does not fetch the demo
PR branches or update an existing checkout. Missing checkouts are cloned from
upstream defaults, which are not sufficient for this integration. See the
[commit plan](STATUS.md#commit-and-pr-plan) for required source revisions.

The recorded ExtProc image also includes unpublished core 0.7.4 compatibility,
Cargo/lockfile and Containerfile wiring changes. A clean source rebuild of that
image is not reproducible from this repository and the listed PRs alone. Use the
recorded-image path until those changes are published. Source builds additionally
require Podman registry login and a writable `IMAGE_REPO`; do not use the default
personal repository unless you have push access.

## Cleanup

```bash
bash praxis_mode/cleanup.sh
# Optional, destructive: also purge owned MaaS API-key storage and its PVC.
bash praxis_mode/cleanup.sh --full
rm -f "$WORK/aitenant.yaml" "$WORK/aitenant.json" "$WORK/live.json" \
  "$WORK/schema-patch.json" "$WORK/controller-role.yaml"
rmdir "$WORK"
```

Cleanup asks you to type the tenant name. Both modes retain shared Responses
storage, certificates and bindings. They also retain image overrides,
supplemental cluster RBAC, RHCL/Authorino, namespaces and AI Gateway/MaaS
enablement. Neither restores AITenant CRD management. Restore management only
after packaged schema/runtime support exists and a platform owner approves the
change. Never force finalizers or delete shared storage to resolve a failed run.
