#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
images_file="${PRAXIS_MVP_IMAGES_FILE:-$script_dir/artifacts/images.env}"
tenant="${PRAXIS_MVP_TENANT:-models-as-a-service}"
gateway_name="${PRAXIS_MVP_GATEWAY:-maas-default-gateway}"
gateway_namespace="${PRAXIS_MVP_GATEWAY_NAMESPACE:-openshift-ingress}"
applications_namespace="${RHOAI_APPLICATIONS_NAMESPACE:-redhat-ods-applications}"
infra_namespace="${PRAXIS_MVP_INFRA_NAMESPACE:-redhat-ai-gateway-infra}"
rhcl_namespace="${PRAXIS_MVP_RHCL_NAMESPACE:-kuadrant-system}"
timeout="${PRAXIS_MVP_TIMEOUT:-15m}"

for command in oc jq openssl yq; do command -v "$command" >/dev/null || { printf 'ERROR: %s is required\n' "$command" >&2; exit 1; }; done
[[ -f "$images_file" ]] || { printf 'ERROR: run build-images.sh first\n' >&2; exit 1; }
: "${LITEMAAS_API_KEY:?set LITEMAAS_API_KEY before creating the workload}"
# shellcheck disable=SC1090
source "$images_file"
oc whoami >/dev/null || { printf 'ERROR: log in to OpenShift first\n' >&2; exit 1; }
oc get clusterpolicy/praxis-mvp-image-swap >/dev/null
oc get datasciencecluster/default-dsc >/dev/null

ensure_namespace() {
  local namespace="$1" phase
  phase="$(oc get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == Terminating ]]; then
    printf 'Waiting for terminating namespace %s to be deleted\n' "$namespace"
    oc wait --for=delete namespace/"$namespace" --timeout="$timeout"
  fi
  oc create namespace "$namespace" --dry-run=client -o yaml | oc apply -f -
}

setup_rhcl() {
  if ! oc get crd authconfigs.authorino.kuadrant.io >/dev/null 2>&1; then
    ensure_namespace "$rhcl_namespace"
    if ! oc get operatorgroup -n "$rhcl_namespace" >/dev/null 2>&1 || \
      [[ -z "$(oc get operatorgroup -n "$rhcl_namespace" -o name)" ]]; then
      oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata: {name: ${rhcl_namespace}-operatorgroup, namespace: $rhcl_namespace}
spec: {}
EOF
    fi
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: {name: rhcl-operator, namespace: $rhcl_namespace}
spec:
  channel: stable
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    oc wait subscription/rhcl-operator -n "$rhcl_namespace" \
      --for=jsonpath='{.status.currentCSV}' --timeout="$timeout"
    rhcl_csv="$(oc get subscription/rhcl-operator -n "$rhcl_namespace" -o jsonpath='{.status.currentCSV}')"
    oc wait --for=create csv/"$rhcl_csv" -n "$rhcl_namespace" --timeout="$timeout"
    oc wait csv/"$rhcl_csv" -n "$rhcl_namespace" \
      --for=jsonpath='{.status.phase}'=Succeeded --timeout="$timeout"
    oc wait --for=condition=Established crd/authconfigs.authorino.kuadrant.io \
      crd/tokenratelimitpolicies.kuadrant.io --timeout="$timeout"
    oc wait --for=create deployment/authorino-operator -n "$rhcl_namespace" --timeout="$timeout"
    oc rollout status deployment/authorino-operator -n "$rhcl_namespace" --timeout="$timeout"
  fi

  oc wait --for=create deployment/limitador-operator-controller-manager \
    -n "$rhcl_namespace" --timeout="$timeout"
  oc rollout status deployment/limitador-operator-controller-manager \
    -n "$rhcl_namespace" --timeout="$timeout"
  if ! oc get kuadrant/kuadrant -n "$rhcl_namespace" >/dev/null 2>&1; then
    oc apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata: {name: kuadrant, namespace: $rhcl_namespace}
spec: {}
EOF
  fi
  # Dependency discovery only runs at Kuadrant operator startup.
  oc delete pod -n "$rhcl_namespace" -l app=kuadrant
  oc rollout status deployment/kuadrant-operator-controller-manager \
    -n "$rhcl_namespace" --timeout="$timeout"
  oc wait kuadrant/kuadrant -n "$rhcl_namespace" --for=condition=Ready --timeout="$timeout"

  oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: openshift-service-ca.crt
  namespace: $rhcl_namespace
  annotations: {service.beta.openshift.io/inject-cabundle: "true"}
EOF
  oc wait configmap/openshift-service-ca.crt -n "$rhcl_namespace" \
    --for=jsonpath='{.data.service-ca\.crt}' --timeout="$timeout"
  # POC only: restore TLS before production use. Service-CA validation remains required for MaaS.
  oc patch authorino/authorino -n "$rhcl_namespace" --type=merge -p \
    '{"spec":{"listener":{"tls":{"enabled":false}},"volumes":{"items":[{"name":"openshift-service-ca","mountPath":"/etc/ssl/certs/openshift-service-ca","configMaps":["openshift-service-ca.crt"],"items":[{"key":"service-ca.crt","path":"service-ca-bundle.crt"}]}]}}}'
  oc set env deployment/authorino -n "$rhcl_namespace" \
    SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
  oc rollout status deployment/authorino -n "$rhcl_namespace" --timeout="$timeout"
}

setup_maas_database() {
  if oc get secret/maas-db-config -n "$infra_namespace" >/dev/null 2>&1; then
    return
  fi

  postgres_image="$(oc get csv -n redhat-ods-operator \
    -l 'operators.coreos.com/rhods-operator.redhat-ods-operator' \
    -o jsonpath='{.items[0].spec.relatedImages[?(@.name=="postgresql_16_image")].image}')"
  [[ -n "$postgres_image" ]] || { printf 'ERROR: RHOAI PostgreSQL image was not found\n' >&2; exit 1; }
  ensure_namespace "$infra_namespace"
  if ! oc get secret/praxis-mvp-maas-postgres -n "$infra_namespace" >/dev/null 2>&1; then
    password="$(openssl rand -hex 16)"
    oc create secret generic praxis-mvp-maas-postgres -n "$infra_namespace" \
      --from-literal=POSTGRESQL_USER=maas \
      --from-literal=POSTGRESQL_PASSWORD="$password" \
      --from-literal=POSTGRESQL_DATABASE=maas
    oc label secret/praxis-mvp-maas-postgres -n "$infra_namespace" \
      app.kubernetes.io/managed-by=praxis-mvp
  fi
  password="$(oc get secret/praxis-mvp-maas-postgres -n "$infra_namespace" \
    -o jsonpath='{.data.POSTGRESQL_PASSWORD}' | base64 --decode)"
  oc apply -n "$infra_namespace" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: praxis-mvp-maas-postgres, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
spec:
  replicas: 1
  selector: {matchLabels: {app: praxis-mvp-maas-postgres}}
  template:
    metadata: {labels: {app: praxis-mvp-maas-postgres}}
    spec:
      containers:
      - name: postgres
        image: $postgres_image
        envFrom: [{secretRef: {name: praxis-mvp-maas-postgres}}]
        ports: [{containerPort: 5432}]
        volumeMounts: [{name: data, mountPath: /var/lib/pgsql/data}]
      volumes: [{name: data, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata: {name: praxis-mvp-maas-postgres, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
spec:
  selector: {app: praxis-mvp-maas-postgres}
  ports: [{port: 5432, targetPort: 5432}]
---
apiVersion: v1
kind: Secret
metadata: {name: maas-db-config, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
stringData:
  DB_CONNECTION_URL: postgresql://maas:$password@praxis-mvp-maas-postgres:5432/maas?sslmode=disable
EOF
  oc rollout status deployment/praxis-mvp-maas-postgres -n "$infra_namespace" --timeout="$timeout"
  if oc get deployment/maas-api -n "$infra_namespace" >/dev/null 2>&1; then
    oc rollout restart deployment/maas-api -n "$infra_namespace"
    oc rollout status deployment/maas-api -n "$infra_namespace" --timeout="$timeout"
  fi
}

setup_rhcl
setup_maas_database

oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: praxis-mvp-ai-gateway-bootstrap, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
rules:
- apiGroups: [networking.istio.io]
  resources: [envoyfilters]
  verbs: [update]
- apiGroups: [networking.k8s.io]
  resources: [networkpolicies]
  verbs: [update]
- apiGroups: [rbac.authorization.k8s.io]
  resources: [clusterroles, clusterrolebindings]
  verbs: [update]
- apiGroups: [maas.opendatahub.io]
  resources: [externalmodels/status]
  verbs: [get, patch, update]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: praxis-mvp-ai-gateway-bootstrap, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: praxis-mvp-ai-gateway-bootstrap}
subjects: [{kind: ServiceAccount, name: ai-gateway-operator, namespace: $applications_namespace}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: praxis-mvp-ai-gateway-controller, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
rules:
- apiGroups: [gateway.networking.k8s.io]
  resources: [httproutes]
  verbs: [patch]
- apiGroups: [networking.istio.io]
  resources: [serviceentries]
  verbs: [patch]
- apiGroups: [maas.opendatahub.io]
  resources: [maastenantconfigs]
  verbs: [get, list, watch]
- apiGroups: [maas.opendatahub.io]
  resources: [aitenants]
  verbs: [get, list, watch, update, patch]
- apiGroups: [maas.opendatahub.io]
  resources: [aitenants/finalizers]
  verbs: [update]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: praxis-mvp-ai-gateway-controller, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: praxis-mvp-ai-gateway-controller}
subjects: [{kind: ServiceAccount, name: ai-gateway-controller, namespace: $applications_namespace}]
EOF

ogx_uid="$(oc get ogxserver ogx-distribution -n "$applications_namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
ogx_pod_uid="$(oc get pod -n "$applications_namespace" -l app=ogx -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || true)"
controller_src="$RUN_DIR/src/controller"
oc apply --server-side --force-conflicts -k "$controller_src/config/crd"
oc apply --server-side --force-conflicts -k "$RUN_DIR/src/operator/config/manifests/maascontroller/crd"
oc kustomize "$RUN_DIR/src/operator/config/manifests/ai-gateway-operator/overlays/rhoai" | \
  yq 'select(.kind == "ClusterRole" and .metadata.name == "ai-gateway-manager-role")' | \
  oc apply --server-side --force-conflicts -f -
oc kustomize "$RUN_DIR/src/operator/config/manifests/maascontroller/default" | \
  yq 'select(.kind == "ClusterRole")' | oc apply --server-side --force-conflicts -f -
oc apply --server-side --force-conflicts -f "$controller_src/config/self/rbac/clusterrole.yaml"

oc patch datasciencecluster/default-dsc --type=merge -p \
  '{"spec":{"components":{"aigateway":{"managementState":"Managed","modelsAsAService":{"managementState":"Managed"}}}}}'
oc wait --for=create deployment/ai-gateway-operator -n "$applications_namespace" --timeout="$timeout"
oc rollout restart deployment/ai-gateway-operator -n "$applications_namespace"
oc rollout status deployment/ai-gateway-operator -n "$applications_namespace" --timeout="$timeout"
oc wait --for=create deployment/maas-controller -n "$applications_namespace" --timeout="$timeout"
oc rollout restart deployment/maas-controller -n "$applications_namespace"
oc rollout status deployment/maas-controller -n "$applications_namespace" --timeout="$timeout"
oc wait --for=create deployment/ai-gateway-controller -n "$applications_namespace" --timeout="$timeout"
oc rollout restart deployment/ai-gateway-controller -n "$applications_namespace"
oc rollout status deployment/ai-gateway-controller -n "$applications_namespace" --timeout="$timeout"
oc apply --server-side --force-conflicts -k "$controller_src/config/crd"
oc apply --server-side --force-conflicts -f "$controller_src/config/self/rbac/clusterrole.yaml"
[[ "$(oc auth can-i patch httproutes.gateway.networking.k8s.io \
  --as="system:serviceaccount:$applications_namespace:ai-gateway-controller" --all-namespaces)" == yes ]] || { printf 'ERROR: controller RBAC is incomplete\n' >&2; exit 1; }
[[ "$(oc auth can-i list maastenantconfigs.maas.opendatahub.io \
  --as="system:serviceaccount:$applications_namespace:ai-gateway-controller" --all-namespaces)" == yes ]] || { printf 'ERROR: controller RBAC is incomplete\n' >&2; exit 1; }
[[ "$(oc auth can-i patch aitenants.maas.opendatahub.io \
  --as="system:serviceaccount:$applications_namespace:ai-gateway-controller" --all-namespaces)" == yes ]] || { printf 'ERROR: controller RBAC is incomplete\n' >&2; exit 1; }

running_image() { oc get pod -n "$1" -l "$2" -o jsonpath='{.items[0].spec.containers[0].image}'; }
[[ "$(running_image "$applications_namespace" control-plane=ai-gateway-controller)" == "$CONTROLLER_IMAGE" ]] || { printf 'ERROR: controller image was not swapped\n' >&2; exit 1; }

if ! oc get gateway "$gateway_name" -n "$gateway_namespace" >/dev/null 2>&1; then
  oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: $gateway_name
  namespace: $gateway_namespace
  labels: {app.kubernetes.io/managed-by: praxis-mvp}
  annotations: {security.opendatahub.io/authorino-tls-bootstrap: "true"}
spec:
  gatewayClassName: data-science-gateway-class
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls: {mode: Terminate, certificateRefs: [{name: data-science-gateway-service-tls}]}
    allowedRoutes: {namespaces: {from: All}}
EOF
fi
oc annotate gateway "$gateway_name" -n "$gateway_namespace" \
  security.opendatahub.io/authorino-tls-bootstrap=true --overwrite
oc wait --for=condition=Programmed gateway/"$gateway_name" -n "$gateway_namespace" --timeout="$timeout"
oc wait --for=create aitenant/"$tenant" -n ai-tenants --timeout="$timeout"
oc annotate aitenant/"$tenant" -n ai-tenants maas.opendatahub.io/payload-processing-type=praxis --overwrite
oc wait --for=condition=Ready aitenant/"$tenant" -n ai-tenants --timeout="$timeout"
tenant_namespace="$(oc get aitenant "$tenant" -n ai-tenants -o jsonpath='{.status.tenantNamespace}')"
[[ -n "$tenant_namespace" ]] || { printf 'ERROR: MaaS did not report a tenant namespace\n' >&2; exit 1; }

oc create secret generic praxis-mvp-provider-credentials -n "$tenant_namespace" \
  --from-literal=api-key="$LITEMAAS_API_KEY" --dry-run=client -o yaml | oc apply -f -
# The apikey-injection secret-watcher only caches Secrets carrying this label, so
# without it the provider credential never reaches the store and requests 500.
oc label secret/praxis-mvp-provider-credentials -n "$tenant_namespace" \
  inference.llm-d.ai/ipp-managed=true app.kubernetes.io/managed-by=praxis-mvp --overwrite
user="$(oc whoami)"
oc apply -f - <<EOF
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalProvider
metadata: {name: praxis-mvp-provider-a, namespace: $tenant_namespace, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
spec: {provider: openai, endpoint: litemaas.rhoai.rh-aiservices-bu.com, auth: {type: apikey, secretRef: {name: praxis-mvp-provider-credentials}}}
---
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata: {name: praxis-mvp-demo, namespace: $tenant_namespace, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
spec:
  modelName: praxis-mvp-demo
  externalProviderRefs:
  - {ref: {name: praxis-mvp-provider-a}, targetModel: Qwen2.5-VL-7B-Instruct, apiFormat: openai-chat, path: /v1/chat/completions, weight: 1}
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata: {name: praxis-mvp-demo, namespace: $tenant_namespace, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
spec: {modelRef: {kind: ExternalModel, name: praxis-mvp-demo}}
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata: {name: praxis-mvp, namespace: $tenant_namespace, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
spec: {owner: {users: [$user]}, modelRefs: [{name: praxis-mvp-demo, namespace: $tenant_namespace, tokenRateLimits: [{limit: 10000, window: 1m}]}], priority: 10}
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata: {name: praxis-mvp, namespace: $tenant_namespace, labels: {app.kubernetes.io/managed-by: praxis-mvp}}
spec: {modelRefs: [{name: praxis-mvp-demo, namespace: $tenant_namespace}], subjects: {users: [$user]}}
EOF

cat >"$script_dir/artifacts/workload.env" <<EOF
TENANT=$tenant
TENANT_NAMESPACE=$tenant_namespace
GATEWAY_NAME=$gateway_name
GATEWAY_NAMESPACE=$gateway_namespace
APPLICATIONS_NAMESPACE=$applications_namespace
MODEL_NAME=praxis-mvp-demo
PROVIDER_MODEL=Qwen2.5-VL-7B-Instruct
OGX_UID=$ogx_uid
OGX_POD_UID=$ogx_pod_uid
EOF
printf 'Praxis workload created in %s. Run ./praxis-mvp/test.sh\n' "$tenant_namespace"
