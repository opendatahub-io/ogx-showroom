#!/usr/bin/env bash
set +x
set -euo pipefail

if [[ "${1:-}" == --help ]]; then
  cat <<'EOF'
Usage: bash praxis_mode/setup.sh [--provision-responses-storage]

Enable packaged RHOAI AI Gateway/MaaS and provision a separate Praxis tenant.
Installs RHCL/Authorino and MaaS PostgreSQL; requires a platform Responses binding.
--provision-responses-storage prepares shared mTLS Responses storage only.
Responses remains disabled. Run praxis_mode/test.sh separately for paid validation.

Overrides: TENANT_NAME (praxis-demo), OPENAI_MODEL (gpt-6-luna),
DSC_NAME (default-dsc), SOURCE_GATEWAY (data-science-gateway),
WAIT_TIMEOUT (600s), RESPONSES_DB_NAME (responses-postgres-praxis-demo).
OPENAI_API_KEY is read from the environment or ls-secrets. Requires cluster-admin.
Resources are retained for reuse. Existing OGX resources are not modified.
EOF
  exit 0
fi
PROVISION_RESPONSES=false
if [[ $# == 1 && "$1" == --provision-responses-storage ]]; then
  PROVISION_RESPONSES=true
elif [[ $# != 0 ]]; then
  echo 'Use --help for usage; run praxis_mode/test.sh separately.' >&2
  exit 2
fi
TENANT_NAME=${TENANT_NAME:-praxis-demo}
OPENAI_MODEL=${OPENAI_MODEL:-gpt-6-luna}
DSC_NAME=${DSC_NAME:-default-dsc}
SOURCE_GATEWAY=${SOURCE_GATEWAY:-data-science-gateway}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-600s}
RESPONSES_DB_NAME=${RESPONSES_DB_NAME:-responses-postgres-praxis-demo}
OWNER=ogx-showroom-praxis

fail() { echo "ERROR: $*" >&2; exit 1; }
for tool in oc jq openssl mktemp cmp sha256sum; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done
[[ "$TENANT_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#TENANT_NAME} -le 30 ]] || fail 'TENANT_NAME must be a DNS label of at most 30 characters'
[[ "$TENANT_NAME" != models-as-a-service ]] || fail 'Use a separate demo tenant, not models-as-a-service'
[[ "$RESPONSES_DB_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#RESPONSES_DB_NAME} -le 59 ]] || fail 'RESPONSES_DB_NAME must be a DNS label of at most 59 characters'
[[ "$OPENAI_MODEL" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ && ${#OPENAI_MODEL} -le 63 ]] || fail 'OPENAI_MODEL must also be a valid MaaSModelRef name'

# Pin subsequent commands to the context selected at startup.
CONTEXT=$(oc config current-context)
OC=(oc --context "$CONTEXT" --request-timeout=30s)
DEMO_USER=$("${OC[@]}" whoami)
if ! "$PROVISION_RESPONSES" && [[ -z "${OPENAI_API_KEY:-}" ]]; then
  command -v ls-secrets >/dev/null || fail 'Set OPENAI_API_KEY or install ls-secrets'
  # shellcheck disable=SC2155
  export OPENAI_API_KEY="$(ls-secrets OPENAI_API_KEY)"
fi
"$PROVISION_RESPONSES" || [[ -n "${OPENAI_API_KEY:-}" ]] || fail 'OPENAI_API_KEY is empty'

echo "Enabling packaged AI Gateway/MaaS on $CONTEXT..."
"${OC[@]}" patch datasciencecluster "$DSC_NAME" --type=merge -p \
  '{"spec":{"components":{"aigateway":{"managementState":"Managed","modelsAsAService":{"managementState":"Managed"}}}}}'
APP_NS=$("${OC[@]}" get dscinitializations.dscinitialization.opendatahub.io -o json | jq -er '.items | select(length == 1) | .[0].spec.applicationsNamespace')
for deployment in ai-gateway-operator maas-controller ai-gateway-controller; do
  "${OC[@]}" wait deployment/"$deployment" -n "$APP_NS" --for=create --timeout="$WAIT_TIMEOUT"
  "${OC[@]}" rollout status deployment/"$deployment" -n "$APP_NS" --timeout="$WAIT_TIMEOUT"
done
"${OC[@]}" get configmap ai-gateway-controller-parameters -n "$APP_NS" -o json | \
  jq -e '.data["praxis-extproc-image"] | strings | select(length > 0)' >/dev/null || fail 'Packaged Praxis image is missing'
for crd in aitenants.maas.opendatahub.io maastenantconfigs.maas.opendatahub.io \
  externalproviders.inference.opendatahub.io externalmodels.inference.opendatahub.io \
  maasmodelrefs.maas.opendatahub.io maassubscriptions.maas.opendatahub.io maasauthpolicies.maas.opendatahub.io; do
  "${OC[@]}" wait crd/"$crd" --for=condition=Established --timeout="$WAIT_TIMEOUT"
done

MANAGER=$("${OC[@]}" get deployment maas-controller -n "$APP_NS" -o json)
GW_NS=$(jq -er '.spec.template.spec.containers[].env[] | select(.name == "GATEWAY_NAMESPACE") | .value' <<<"$MANAGER")
AITENANT_NS=$(jq -er '.spec.template.spec.containers[].env[] | select(.name == "AITENANT_NAMESPACE") | .value' <<<"$MANAGER")
INFRA_NS=$(jq -er '.spec.template.spec.containers[].env[] | select(.name == "INFRA_NAMESPACE") | .value' <<<"$MANAGER")
SOURCE=$("${OC[@]}" get gateway "$SOURCE_GATEWAY" -n "$GW_NS" -o json)
GW_CLASS=$(jq -er '.spec.gatewayClassName' <<<"$SOURCE")
GATEWAY="$TENANT_NAME-gateway"

check_owner() {
  local resource=$1 name=$2 namespace=$3 existing
  existing=$("${OC[@]}" get "$resource" "$name" -n "$namespace" --ignore-not-found -o json)
  [[ -z "$existing" ]] || jq -e --arg owner "$OWNER" \
    '.metadata.labels["app.kubernetes.io/managed-by"] == $owner' <<<"$existing" >/dev/null || \
    fail "Refusing to overwrite existing $namespace/$resource/$name"
}
apply_resource() {
  local resource=$1 name=$2 namespace=$3 object=$4
  check_owner "$resource" "$name" "$namespace"
  jq --arg owner "$OWNER" '.metadata.labels["app.kubernetes.io/managed-by"] = $owner' <<<"$object" | \
    "${OC[@]}" apply --server-side --field-manager="$OWNER" -f -
}

setup_responses_database() {
  local name="$RESPONSES_DB_NAME" host image tls key binding config_hash
  host="$name.$INFRA_NS.svc.cluster.local"
  echo "Preparing retained Responses PostgreSQL with mTLS in $INFRA_NS..."
  for resource in deployment service pvc configmap networkpolicy; do
    check_owner "$resource" "$name" "$INFRA_NS"
  done
  check_owner secret "$name-tls" "$INFRA_NS"
  check_owner secret responses-db-config "$INFRA_NS"
  check_owner secret responses-db-ca "$INFRA_NS"
  image=$("${OC[@]}" get clusterserviceversions.operators.coreos.com -n "$APP_NS" -o json | jq -er '[.items[].spec.relatedImages[]? | select(.name == "postgresql_16_image") | .image] | first | select(length > 0)')
  RESPONSES_WORK=$(mktemp -d /tmp/opencode/praxis-responses.XXXXXXXX)
  trap 'rm -rf -- "$RESPONSES_WORK"' EXIT
  chmod 700 "$RESPONSES_WORK"
  tls=$("${OC[@]}" get secret "$name-tls" -n "$INFRA_NS" --ignore-not-found -o json)
  if [[ -n "$tls" ]]; then
    for key in ca.crt ca.key server.crt server.key client.crt client.key POSTGRES_PASSWORD; do
      jq -ej --arg key "$key" '.data[$key] | strings | select(length > 0) | @base64d' <<<"$tls" > "$RESPONSES_WORK/$key"
      chmod 600 "$RESPONSES_WORK/$key"
    done
  else
    [[ -z $("${OC[@]}" get pvc "$name" -n "$INFRA_NS" --ignore-not-found -o name) ]] || fail 'Responses PVC exists but TLS credentials are missing; restore the Secret, do not rotate it'
    for key in responses-db-config responses-db-ca; do
      [[ -z $("${OC[@]}" get secret "$key" -n "$INFRA_NS" --ignore-not-found -o name) ]] || fail 'Responses binding exists without server credentials; restore them first'
    done
    (
      umask 077
      cd "$RESPONSES_WORK"
      openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out ca.key 2>/dev/null
      openssl req -new -x509 -key ca.key -sha256 -days 3650 -subj "/CN=$name-ca" \
        -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -out ca.crt
      for key in server client; do
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$key.key" 2>/dev/null
      done
      openssl req -new -key server.key -subj "/CN=$name" -out server.csr
      printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s,IP:127.0.0.1\n' "$host" > server.ext
      openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days 365 -extfile server.ext -out server.crt 2>/dev/null
      openssl req -new -key client.key -subj '/CN=responses' -out client.csr
      printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' > client.ext
      openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAserial ca.srl -sha256 -days 365 -extfile client.ext -out client.crt 2>/dev/null
      openssl rand -hex 24 > POSTGRES_PASSWORD
    )
  fi
  unset tls
  for key in ca server client; do
    openssl x509 -in "$RESPONSES_WORK/$key.crt" -checkend 0 -noout >/dev/null || fail "Responses $key certificate expired; renew explicitly"
    cmp <(openssl x509 -in "$RESPONSES_WORK/$key.crt" -pubkey -noout) \
      <(openssl pkey -in "$RESPONSES_WORK/$key.key" -pubout) >/dev/null || fail "Responses $key certificate/key mismatch"
  done
  openssl verify -CAfile "$RESPONSES_WORK/ca.crt" -purpose sslserver -verify_hostname "$host" "$RESPONSES_WORK/server.crt" >/dev/null || fail 'Responses server certificate verification failed'
  openssl verify -CAfile "$RESPONSES_WORK/ca.crt" -purpose sslclient "$RESPONSES_WORK/client.crt" >/dev/null || fail 'Responses client certificate verification failed'
  [[ $(openssl x509 -in "$RESPONSES_WORK/client.crt" -noout -subject -nameopt RFC2253) == 'subject=CN=responses' ]] || fail 'Responses client certificate must identify the dedicated responses role'
  jq -n --arg ns "$INFRA_NS" --arg owner "$OWNER" --arg host "$host" \
    --rawfile cert "$RESPONSES_WORK/client.crt" --rawfile key "$RESPONSES_WORK/client.key" \
    '{apiVersion:"v1",kind:"Secret",metadata:{name:"responses-db-config",namespace:$ns,labels:{"app.kubernetes.io/managed-by":$owner,"ogx-showroom-praxis/storage":"responses"}},type:"Opaque",data:{DB_CONNECTION_URL:(("postgresql://responses@"+$host+":5432/responses")|@base64),"tls.crt":($cert|@base64),"tls.key":($key|@base64)}}' > "$RESPONSES_WORK/responses-db-config.json"
  jq -n --arg ns "$INFRA_NS" --arg owner "$OWNER" --rawfile ca "$RESPONSES_WORK/ca.crt" \
    '{apiVersion:"v1",kind:"Secret",metadata:{name:"responses-db-ca",namespace:$ns,labels:{"app.kubernetes.io/managed-by":$owner,"ogx-showroom-praxis/storage":"responses"}},type:"Opaque",data:{"ca.crt":($ca|@base64)}}' > "$RESPONSES_WORK/responses-db-ca.json"
  for key in responses-db-config responses-db-ca; do
    chmod 600 "$RESPONSES_WORK/$key.json"
    binding=$("${OC[@]}" get secret "$key" -n "$INFRA_NS" --ignore-not-found -o json)
    if [[ -n "$binding" ]]; then
      jq -e --slurpfile expected "$RESPONSES_WORK/$key.json" '.data == $expected[0].data' <<<"$binding" >/dev/null || fail 'Existing Responses binding differs from retained credentials; refusing to overwrite it'
    fi
  done
  unset binding
  "${OC[@]}" create secret generic "$name-tls" -n "$INFRA_NS" --dry-run=client -o json \
    --from-file="ca.crt=$RESPONSES_WORK/ca.crt" --from-file="ca.key=$RESPONSES_WORK/ca.key" \
    --from-file="server.crt=$RESPONSES_WORK/server.crt" --from-file="server.key=$RESPONSES_WORK/server.key" \
    --from-file="client.crt=$RESPONSES_WORK/client.crt" --from-file="client.key=$RESPONSES_WORK/client.key" \
    --from-file="POSTGRES_PASSWORD=$RESPONSES_WORK/POSTGRES_PASSWORD" | \
    jq --arg owner "$OWNER" '.metadata.labels={"app.kubernetes.io/managed-by":$owner,"ogx-showroom-praxis/storage":"responses"}' | \
    "${OC[@]}" apply --server-side --field-manager="$OWNER" -f -
  cat > "$RESPONSES_WORK/tls.conf" <<'EOF'
ssl = on
ssl_min_protocol_version = 'TLSv1.2'
ssl_cert_file = '/var/lib/pgsql/data/responses-tls/server.crt'
ssl_key_file = '/var/lib/pgsql/data/responses-tls/server.key'
ssl_ca_file = '/var/lib/pgsql/data/responses-tls/ca.crt'
hba_file = '/etc/responses-postgres/pg_hba.conf'
EOF
  cat > "$RESPONSES_WORK/pg_hba.conf" <<'EOF'
local all postgres peer
hostssl responses responses 0.0.0.0/0 cert
hostssl responses responses ::/0 cert
host all all 0.0.0.0/0 reject
host all all ::/0 reject
EOF
  cat > "$RESPONSES_WORK/prepare-tls.sh" <<'EOF'
umask 077
mkdir -p /var/lib/pgsql/data/responses-tls
chmod 700 /var/lib/pgsql/data/responses-tls
for file in ca.crt server.crt server.key client.crt client.key; do
  cat "/etc/responses-tls/$file" > "/var/lib/pgsql/data/responses-tls/$file"
done
chmod 600 /var/lib/pgsql/data/responses-tls/*.key
EOF
  cat > "$RESPONSES_WORK/check-mtls.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
unset PGPASSWORD PGSERVICE PGSERVICEFILE PGSSLCERT PGSSLKEY
export PGCONNECT_TIMEOUT=5
connection='host=127.0.0.1 user=responses dbname=responses sslmode=verify-full sslrootcert=/var/lib/pgsql/data/responses-tls/ca.crt sslcert=/var/lib/pgsql/data/responses-tls/client.crt sslkey=/var/lib/pgsql/data/responses-tls/client.key'
psql -X -w -At -d "$connection" -c 'SELECT 1' >/dev/null
if [[ ${1:-} == negative ]]; then
  if error=$(psql -X -w -d 'host=127.0.0.1 user=responses dbname=responses sslmode=disable' -c 'SELECT 1' 2>&1); then
    echo 'Plaintext database connection unexpectedly accepted' >&2
    exit 1
  fi
  [[ "$error" == *'pg_hba.conf rejects connection'* && "$error" == *'no encryption'* ]] || { echo "Plaintext rejection could not be verified: $error" >&2; exit 1; }
  if error=$(psql -X -w -d "host=127.0.0.1 user=responses dbname=responses sslmode=verify-full sslrootcert=/var/lib/pgsql/data/responses-tls/ca.crt sslcert='' sslkey=''" -c 'SELECT 1' 2>&1); then
    echo 'Database connection without client certificate unexpectedly accepted' >&2
    exit 1
  fi
  [[ "$error" == *'requires a valid client certificate'* ]] || { echo "Client-certificate rejection could not be verified: $error" >&2; exit 1; }
fi
EOF
  apply_resource configmap "$name" "$INFRA_NS" "$(jq -n --arg name "$name" --arg ns "$INFRA_NS" \
    --rawfile config "$RESPONSES_WORK/tls.conf" --rawfile hba "$RESPONSES_WORK/pg_hba.conf" \
    --rawfile prepare "$RESPONSES_WORK/prepare-tls.sh" --rawfile check "$RESPONSES_WORK/check-mtls.sh" \
    '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$name,namespace:$ns},data:{"tls.conf":$config,"pg_hba.conf":$hba,"prepare-tls.sh":$prepare,"check-mtls.sh":$check}}')"
  config_hash=$(cat "$RESPONSES_WORK/tls.conf" "$RESPONSES_WORK/pg_hba.conf" "$RESPONSES_WORK/prepare-tls.sh" "$RESPONSES_WORK/check-mtls.sh" | sha256sum | cut -d ' ' -f 1)
  apply_resource pvc "$name" "$INFRA_NS" "$(jq -n --arg name "$name" --arg ns "$INFRA_NS" \
    '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:$name,namespace:$ns},spec:{accessModes:["ReadWriteOnce"],resources:{requests:{storage:"1Gi"}}}}')"
  apply_resource service "$name" "$INFRA_NS" "$(jq -n --arg name "$name" --arg ns "$INFRA_NS" \
    '{apiVersion:"v1",kind:"Service",metadata:{name:$name,namespace:$ns},spec:{selector:{app:$name},ports:[{port:5432,targetPort:5432}]}}')"
  apply_resource networkpolicy "$name" "$INFRA_NS" "$(jq -n --arg name "$name" --arg ns "$INFRA_NS" \
    '{apiVersion:"networking.k8s.io/v1",kind:"NetworkPolicy",metadata:{name:$name,namespace:$ns},spec:{podSelector:{matchLabels:{app:$name}},policyTypes:["Ingress"],ingress:[{from:[{namespaceSelector:{},podSelector:{matchLabels:{app:"payload-processing-external-model"},matchExpressions:[{key:"ai-gateway-controller.opendatahub.io/responses-tenant-uid",operator:"Exists"}]}}],ports:[{protocol:"TCP",port:5432}]}]}}')"
  apply_resource deployment "$name" "$INFRA_NS" "$(jq -n --arg name "$name" --arg ns "$INFRA_NS" --arg image "$image" --arg hash "$config_hash" \
    '{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:$name,namespace:$ns},spec:{replicas:1,strategy:{type:"Recreate"},selector:{matchLabels:{app:$name}},template:{metadata:{labels:{app:$name},annotations:{"ogx-showroom-praxis/config-sha256":$hash}},spec:{containers:[{name:"postgres",image:$image,env:[{name:"POSTGRESQL_USER",value:"responses"},{name:"POSTGRESQL_DATABASE",value:"responses"},{name:"POSTGRESQL_PASSWORD",valueFrom:{secretKeyRef:{name:($name+"-tls"),key:"POSTGRES_PASSWORD"}}}],ports:[{containerPort:5432}],volumeMounts:[{name:"data",mountPath:"/var/lib/pgsql/data"},{name:"tls",mountPath:"/etc/responses-tls",readOnly:true},{name:"config",mountPath:"/etc/responses-postgres",readOnly:true},{name:"settings",mountPath:"/opt/app-root/src/postgresql-cfg",readOnly:true},{name:"prepare",mountPath:"/opt/app-root/src/postgresql-pre-start",readOnly:true}],readinessProbe:{exec:{command:["bash","/etc/responses-postgres/check-mtls.sh"]},initialDelaySeconds:10,periodSeconds:10,timeoutSeconds:10},resources:{requests:{cpu:"100m",memory:"256Mi"},limits:{memory:"512Mi"}},securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}],volumes:[{name:"data",persistentVolumeClaim:{claimName:$name}},{name:"tls",secret:{secretName:($name+"-tls"),defaultMode:292,items:(["ca.crt","server.crt","server.key","client.crt","client.key"]|map({key:.,path:.}))}},{name:"config",configMap:{name:$name}},{name:"settings",configMap:{name:$name,items:[{key:"tls.conf",path:"tls.conf"}]}},{name:"prepare",configMap:{name:$name,items:[{key:"prepare-tls.sh",path:"prepare-tls.sh"}]}}]}}}}')"
  "${OC[@]}" rollout status deployment/"$name" -n "$INFRA_NS" --timeout="$WAIT_TIMEOUT"
  "${OC[@]}" exec deployment/"$name" -n "$INFRA_NS" -- bash /etc/responses-postgres/check-mtls.sh negative
  for key in responses-db-config responses-db-ca; do
    "${OC[@]}" apply --server-side --field-manager="$OWNER" -f "$RESPONSES_WORK/$key.json"
  done
  rm -rf -- "$RESPONSES_WORK"
  trap - EXIT
  echo 'Responses database mTLS checks passed; provisioning does not enable the APIs.'
}

if "$PROVISION_RESPONSES"; then
  setup_responses_database
  exit 0
fi

for name in responses-db-config responses-db-ca; do
  "${OC[@]}" get secret "$name" -n "$INFRA_NS" -o json | jq -e --arg name "$name" \
    'if $name == "responses-db-ca" then .data["ca.crt"] | strings | select(length > 0)
     else .data | all([.DB_CONNECTION_URL, .["tls.crt"], .["tls.key"]][]; type == "string" and length > 0) end' >/dev/null || \
    fail 'Provision the platform Responses binding before tenant setup (--provision-responses-storage)'
done

echo 'Setting up packaged RHCL authentication and rate limiting...'
SUBSCRIPTIONS=$("${OC[@]}" get subscriptions.operators.coreos.com -A -o json | jq '[.items[] | select(.spec.name == "rhcl-operator" or .spec.name == "kuadrant-operator")]')
[[ $(jq length <<<"$SUBSCRIPTIONS") -le 1 ]] || fail 'Multiple RHCL/Kuadrant installations found; select one before continuing'
if [[ $(jq length <<<"$SUBSCRIPTIONS") == 0 ]]; then
  AUTH_NS=kuadrant-system
  SUBSCRIPTION=kuadrant-operator
  if ! "${OC[@]}" get namespace "$AUTH_NS" >/dev/null 2>&1; then
    "${OC[@]}" create namespace "$AUTH_NS"
  fi
  GROUP_COUNT=$("${OC[@]}" get operatorgroups.operators.coreos.com -n "$AUTH_NS" -o json | jq '.items | length')
  [[ "$GROUP_COUNT" -le 1 ]] || fail "Multiple OperatorGroups found in $AUTH_NS"
  if [[ "$GROUP_COUNT" == 0 ]]; then
    apply_resource operatorgroups.operators.coreos.com kuadrant-operator-group "$AUTH_NS" "$(jq -n --arg ns "$AUTH_NS" \
      '{apiVersion:"operators.coreos.com/v1",kind:"OperatorGroup",metadata:{name:"kuadrant-operator-group",namespace:$ns},spec:{}}')"
  fi
  apply_resource subscriptions.operators.coreos.com "$SUBSCRIPTION" "$AUTH_NS" "$(jq -n --arg ns "$AUTH_NS" \
    '{apiVersion:"operators.coreos.com/v1alpha1",kind:"Subscription",metadata:{name:"kuadrant-operator",namespace:$ns},spec:{channel:"stable",installPlanApproval:"Automatic",name:"rhcl-operator",source:"redhat-operators",sourceNamespace:"openshift-marketplace",config:{env:[{name:"RATELIMIT_CHECK_SERVICE_FAILURE_MODE",value:"deny"},{name:"RATELIMIT_REPORT_SERVICE_FAILURE_MODE",value:"deny"}]}}}')"
else
  AUTH_NS=$(jq -r '.[0].metadata.namespace' <<<"$SUBSCRIPTIONS")
  SUBSCRIPTION=$(jq -r '.[0].metadata.name' <<<"$SUBSCRIPTIONS")
  echo "Reusing RHCL/Kuadrant subscription $AUTH_NS/$SUBSCRIPTION"
fi
"${OC[@]}" wait subscriptions.operators.coreos.com/"$SUBSCRIPTION" -n "$AUTH_NS" --for=jsonpath='{.status.state}'=AtLatestKnown --timeout="$WAIT_TIMEOUT"
CSV=$("${OC[@]}" get subscriptions.operators.coreos.com "$SUBSCRIPTION" -n "$AUTH_NS" -o json | jq -er '.status.installedCSV | select(length > 0)')
"${OC[@]}" wait clusterserviceversions.operators.coreos.com/"$CSV" -n "$AUTH_NS" --for=jsonpath='{.status.phase}'=Succeeded --timeout="$WAIT_TIMEOUT"
for crd in kuadrants.kuadrant.io authpolicies.kuadrant.io tokenratelimitpolicies.kuadrant.io authconfigs.authorino.kuadrant.io authorinos.operator.authorino.kuadrant.io; do
  "${OC[@]}" wait crd/"$crd" --for=create --timeout="$WAIT_TIMEOUT"
  "${OC[@]}" wait crd/"$crd" --for=condition=Established --timeout="$WAIT_TIMEOUT"
done
KUADRANTS=$("${OC[@]}" get kuadrants.kuadrant.io -A -o json)
if [[ $(jq '.items | length' <<<"$KUADRANTS") == 0 ]]; then
  apply_resource kuadrants.kuadrant.io kuadrant "$AUTH_NS" "$(jq -n --arg ns "$AUTH_NS" \
    '{apiVersion:"kuadrant.io/v1beta1",kind:"Kuadrant",metadata:{name:"kuadrant",namespace:$ns},spec:{}}')"
else
  [[ $(jq '.items | length' <<<"$KUADRANTS") == 1 ]] || fail 'Multiple Kuadrant instances found'
  [[ $(jq -r '.items[0].metadata.namespace' <<<"$KUADRANTS") == "$AUTH_NS" ]] || fail 'Kuadrant instance is outside the operator namespace'
fi
KUADRANT=$("${OC[@]}" get kuadrants.kuadrant.io -n "$AUTH_NS" -o json | jq -er '.items | select(length == 1) | .[0].metadata.name')
"${OC[@]}" wait authorinos.operator.authorino.kuadrant.io/authorino -n "$AUTH_NS" --for=create --timeout="$WAIT_TIMEOUT"
"${OC[@]}" wait service/authorino-authorino-authorization -n "$AUTH_NS" --for=create --timeout="$WAIT_TIMEOUT"
"${OC[@]}" annotate service authorino-authorino-authorization -n "$AUTH_NS" service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite
"${OC[@]}" wait secret/authorino-server-cert -n "$AUTH_NS" --for=create --timeout="$WAIT_TIMEOUT"
"${OC[@]}" patch authorinos.operator.authorino.kuadrant.io authorino -n "$AUTH_NS" --type=merge -p \
  '{"spec":{"listener":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-server-cert"}}}}}'
"${OC[@]}" wait deployment/authorino -n "$AUTH_NS" --for=create --timeout="$WAIT_TIMEOUT"
"${OC[@]}" set env deployment/authorino -n "$AUTH_NS" \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
"${OC[@]}" rollout status deployment/authorino -n "$AUTH_NS" --timeout="$WAIT_TIMEOUT"
"${OC[@]}" wait kuadrants.kuadrant.io/"$KUADRANT" -n "$AUTH_NS" --for=condition=Ready --timeout="$WAIT_TIMEOUT"

echo "Setting up MaaS database in $INFRA_NS..."
"${OC[@]}" wait namespace/"$INFRA_NS" --for=create --timeout="$WAIT_TIMEOUT"
DB_CONFIG=$("${OC[@]}" get secret maas-db-config -n "$INFRA_NS" --ignore-not-found -o json)
if [[ -n "$DB_CONFIG" ]] && ! jq -e --arg owner "$OWNER" '.metadata.labels["app.kubernetes.io/managed-by"] == $owner' <<<"$DB_CONFIG" >/dev/null; then
  jq -e '.data.DB_CONNECTION_URL | strings | select(length > 0)' <<<"$DB_CONFIG" >/dev/null || fail 'Existing maas-db-config has no DB_CONNECTION_URL'
  echo 'Reusing existing MaaS database configuration without modifying it.'
else
  PG_IMAGE=$("${OC[@]}" get clusterserviceversions.operators.coreos.com -n "$APP_NS" -o json | jq -er '[.items[].spec.relatedImages[]? | select(.name == "postgresql_16_image") | .image] | first | select(length > 0)')
  check_owner secret maas-postgres-credentials "$INFRA_NS"
  PG_SECRET=$("${OC[@]}" get secret maas-postgres-credentials -n "$INFRA_NS" --ignore-not-found -o json)
  if [[ -n "$PG_SECRET" ]]; then
    PG_PASSWORD=$(jq -er '.data.POSTGRES_PASSWORD | @base64d | select(length > 0)' <<<"$PG_SECRET")
  else
    [[ -z $("${OC[@]}" get pvc maas-postgres-data -n "$INFRA_NS" --ignore-not-found -o name) ]] || fail 'MaaS database PVC exists but credentials are missing; restore its credentials first'
    PG_PASSWORD=$(openssl rand -hex 24)
    printf '%s' "$PG_PASSWORD" | jq -Rs --arg ns "$INFRA_NS" --arg owner "$OWNER" \
      '{apiVersion:"v1",kind:"Secret",metadata:{name:"maas-postgres-credentials",namespace:$ns,labels:{"app.kubernetes.io/managed-by":$owner}},data:{POSTGRES_PASSWORD:(. | @base64)}}' | \
      "${OC[@]}" apply --server-side --field-manager="$OWNER" -f -
  fi
  apply_resource pvc maas-postgres-data "$INFRA_NS" "$(jq -n --arg ns "$INFRA_NS" \
    '{apiVersion:"v1",kind:"PersistentVolumeClaim",metadata:{name:"maas-postgres-data",namespace:$ns},spec:{accessModes:["ReadWriteOnce"],resources:{requests:{storage:"1Gi"}}}}')"
  apply_resource service maas-postgres "$INFRA_NS" "$(jq -n --arg ns "$INFRA_NS" \
    '{apiVersion:"v1",kind:"Service",metadata:{name:"maas-postgres",namespace:$ns},spec:{selector:{app:"maas-postgres"},ports:[{port:5432,targetPort:5432}]}}')"
  apply_resource deployment maas-postgres "$INFRA_NS" "$(jq -n --arg ns "$INFRA_NS" --arg image "$PG_IMAGE" \
    '{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:"maas-postgres",namespace:$ns},spec:{replicas:1,strategy:{type:"Recreate"},selector:{matchLabels:{app:"maas-postgres"}},template:{metadata:{labels:{app:"maas-postgres"}},spec:{containers:[{name:"postgres",image:$image,env:[{name:"POSTGRESQL_USER",value:"maas"},{name:"POSTGRESQL_DATABASE",value:"maas"},{name:"POSTGRESQL_PASSWORD",valueFrom:{secretKeyRef:{name:"maas-postgres-credentials",key:"POSTGRES_PASSWORD"}}}],ports:[{containerPort:5432}],volumeMounts:[{name:"data",mountPath:"/var/lib/pgsql/data"}],readinessProbe:{exec:{command:["/usr/libexec/check-container"]},initialDelaySeconds:5,periodSeconds:5},resources:{requests:{cpu:"100m",memory:"256Mi"},limits:{memory:"512Mi"}},securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},seccompProfile:{type:"RuntimeDefault"}}}],volumes:[{name:"data",persistentVolumeClaim:{claimName:"maas-postgres-data"}}]}}}}')"
  "${OC[@]}" rollout status deployment/maas-postgres -n "$INFRA_NS" --timeout="$WAIT_TIMEOUT"
  check_owner secret maas-db-config "$INFRA_NS"
  printf '%s' "$PG_PASSWORD" | jq -Rs --arg ns "$INFRA_NS" --arg owner "$OWNER" \
    '{apiVersion:"v1",kind:"Secret",metadata:{name:"maas-db-config",namespace:$ns,labels:{"app.kubernetes.io/managed-by":$owner}},data:{DB_CONNECTION_URL:(("postgresql://maas:"+(. | @uri)+"@maas-postgres."+$ns+".svc.cluster.local:5432/maas?sslmode=disable") | @base64)}}' | \
    "${OC[@]}" apply --server-side --field-manager="$OWNER" -f -
  unset PG_PASSWORD PG_SECRET
  apply_resource networkpolicy "$TENANT_NAME-maas-db-egress" "$INFRA_NS" "$(jq -n --arg name "$TENANT_NAME-maas-db-egress" --arg ns "$INFRA_NS" --arg instance "maas-api-$TENANT_NAME" \
    '{apiVersion:"networking.k8s.io/v1",kind:"NetworkPolicy",metadata:{name:$name,namespace:$ns},spec:{podSelector:{matchLabels:{"maas.opendatahub.io/tenant-instance":$instance}},policyTypes:["Egress"],egress:[{to:[{podSelector:{matchLabels:{app:"maas-postgres"}}}],ports:[{protocol:"TCP",port:5432}]}]}}')"
fi
unset DB_CONFIG

# Istio generates the Service; OpenShift service-ca supplies its TLS certificate.
apply_resource configmap "$GATEWAY-config" "$GW_NS" "$(jq -n --arg name "$GATEWAY-config" --arg ns "$GW_NS" --arg secret "$GATEWAY-tls" \
  '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$name,namespace:$ns},data:{service:({metadata:{annotations:{"service.beta.openshift.io/serving-cert-secret-name":$secret}},spec:{type:"ClusterIP"}} | tojson)}}')"
apply_resource gateway "$GATEWAY" "$GW_NS" "$(jq -n --arg name "$GATEWAY" --arg ns "$GW_NS" --arg class "$GW_CLASS" \
  '{apiVersion:"gateway.networking.k8s.io/v1",kind:"Gateway",metadata:{name:$name,namespace:$ns,labels:{"kuadrant.io/gateway":"true"}},spec:{gatewayClassName:$class,infrastructure:{parametersRef:{group:"",kind:"ConfigMap",name:($name+"-config")}},listeners:[{name:"https",port:443,protocol:"HTTPS",tls:{mode:"Terminate",certificateRefs:[{kind:"Secret",name:($name+"-tls")}]},allowedRoutes:{namespaces:{from:"Selector",selector:{matchLabels:{"maas.opendatahub.io/gateway-access":"true"}}}}}]}}')"
"${OC[@]}" wait gateway/"$GATEWAY" -n "$GW_NS" --for=condition=Programmed --timeout="$WAIT_TIMEOUT"

# Istio keeps the first ADD for a cluster name; MERGE does not affect added clusters.
AUTH_HOST="authorino-authorino-authorization.$AUTH_NS.svc.cluster.local"
apply_resource envoyfilters.networking.istio.io "$GATEWAY-authorino-tls" "$GW_NS" "$(jq -n \
  --arg name "$GATEWAY-authorino-tls" --arg ns "$GW_NS" --arg gateway "$GATEWAY" --arg host "$AUTH_HOST" \
  '{apiVersion:"networking.istio.io/v1alpha3",kind:"EnvoyFilter",metadata:{name:$name,namespace:$ns},spec:{priority:-10,workloadSelector:{labels:{"gateway.networking.k8s.io/gateway-name":$gateway}},configPatches:[{applyTo:"CLUSTER",match:{context:"GATEWAY"},patch:{operation:"ADD",value:{name:"kuadrant-auth-service",type:"STRICT_DNS",connect_timeout:"1s",lb_policy:"ROUND_ROBIN",http2_protocol_options:{},load_assignment:{cluster_name:"kuadrant-auth-service",endpoints:[{lb_endpoints:[{endpoint:{address:{socket_address:{address:$host,port_value:50051}}}}]}]},transport_socket:{name:"envoy.transport_sockets.tls",typed_config:{"@type":"type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext",sni:$host,common_tls_context:{alpn_protocols:["h2"],validation_context:{trusted_ca:{filename:"/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt"},match_typed_subject_alt_names:[{san_type:"DNS",matcher:{exact:$host}}]}}}}}}}]}}')"

apply_resource aitenants.maas.opendatahub.io "$TENANT_NAME" "$AITENANT_NS" "$(jq -n --arg tenant "$TENANT_NAME" --arg ns "$AITENANT_NS" --arg gateway "$GATEWAY" --arg user "$DEMO_USER" \
  '{apiVersion:"maas.opendatahub.io/v1alpha1",kind:"AITenant",metadata:{name:$tenant,namespace:$ns},spec:{gateway:{name:$gateway},rbac:{admins:[{kind:"User",name:$user}]}}}')"
echo "Waiting for AITenant $AITENANT_NS/$TENANT_NAME to become Ready..."
if ! "${OC[@]}" wait aitenants.maas.opendatahub.io/"$TENANT_NAME" -n "$AITENANT_NS" --for=condition=Ready --timeout="$WAIT_TIMEOUT"; then
  "${OC[@]}" get aitenants.maas.opendatahub.io "$TENANT_NAME" -n "$AITENANT_NS" -o json | jq '.status' >&2
  "${OC[@]}" get maastenantconfigs.maas.opendatahub.io -A -l "maas.opendatahub.io/tenant-name=$TENANT_NAME" -o json | jq '.items[] | {namespace:.metadata.namespace,status}' >&2
  fail 'Tenant readiness failed; check MaaS API pods and the reported dependency conditions'
fi
TENANT_NS=$("${OC[@]}" get aitenants.maas.opendatahub.io "$TENANT_NAME" -n "$AITENANT_NS" -o json | jq -er '.status.tenantNamespace | select(length > 0)')
[[ "$TENANT_NS" == "ai-tenant-$TENANT_NAME" ]] || fail "Unexpected tenant namespace: $TENANT_NS"
"${OC[@]}" wait maastenantconfigs.maas.opendatahub.io/default-tenant -n "$TENANT_NS" --for=create --timeout="$WAIT_TIMEOUT"
"${OC[@]}" annotate maastenantconfigs.maas.opendatahub.io default-tenant -n "$TENANT_NS" \
  maas.opendatahub.io/payload-processing-type=praxis --overwrite
"${OC[@]}" wait maastenantconfigs.maas.opendatahub.io/default-tenant -n "$TENANT_NS" \
  --for=jsonpath='{.metadata.annotations.maas\.opendatahub\.io/payload-processing-status}'=steady --timeout="$WAIT_TIMEOUT"

# TODO: Fix packaged controller RBAC; ExternalModel finalizer creation/removal needs patch.
CONTROLLER_SA=$("${OC[@]}" get deployment ai-gateway-controller -n "$APP_NS" -o json | jq -er '.spec.template.spec.serviceAccountName | select(length > 0)')
apply_resource role "$TENANT_NAME-model-finalizer" "$TENANT_NS" "$(jq -n --arg name "$TENANT_NAME-model-finalizer" --arg ns "$TENANT_NS" \
  '{apiVersion:"rbac.authorization.k8s.io/v1",kind:"Role",metadata:{name:$name,namespace:$ns},rules:[{apiGroups:["inference.opendatahub.io"],resources:["externalmodels"],resourceNames:["openai-model"],verbs:["patch"]}]}')"
apply_resource rolebinding "$TENANT_NAME-model-finalizer" "$TENANT_NS" "$(jq -n --arg name "$TENANT_NAME-model-finalizer" --arg ns "$TENANT_NS" --arg appns "$APP_NS" --arg sa "$CONTROLLER_SA" \
  '{apiVersion:"rbac.authorization.k8s.io/v1",kind:"RoleBinding",metadata:{name:$name,namespace:$ns},roleRef:{apiGroup:"rbac.authorization.k8s.io",kind:"Role",name:$name},subjects:[{kind:"ServiceAccount",name:$sa,namespace:$appns}]}')"

check_owner secret openai-provider-credentials "$TENANT_NS"
# Never put credentials in arguments, generated files, or last-applied annotations.
printf '%s' "$OPENAI_API_KEY" | jq -Rs --arg ns "$TENANT_NS" --arg owner "$OWNER" \
  '{apiVersion:"v1",kind:"Secret",metadata:{name:"openai-provider-credentials",namespace:$ns,labels:{"app.kubernetes.io/managed-by":$owner}},type:"Opaque",data:{"api-key":(. | @base64)}}' | \
  "${OC[@]}" apply --server-side --field-manager="$OWNER" -f -
unset OPENAI_API_KEY
apply_resource externalproviders.inference.opendatahub.io openai "$TENANT_NS" "$(jq -n --arg ns "$TENANT_NS" \
  '{apiVersion:"inference.opendatahub.io/v1alpha1",kind:"ExternalProvider",metadata:{name:"openai",namespace:$ns},spec:{provider:"openai",endpoint:"api.openai.com",auth:{type:"apikey",secretRef:{name:"openai-provider-credentials"}}}}')"
apply_resource externalmodels.inference.opendatahub.io openai-model "$TENANT_NS" "$(jq -n --arg ns "$TENANT_NS" --arg model "$OPENAI_MODEL" \
  '{apiVersion:"inference.opendatahub.io/v1alpha1",kind:"ExternalModel",metadata:{name:"openai-model",namespace:$ns},spec:{modelName:$model,externalProviderRefs:[{ref:{name:"openai"},targetModel:$model,apiFormat:"openai-chat",path:"/v1/chat/completions"}]}}')"
apply_resource maasmodelrefs.maas.opendatahub.io "$OPENAI_MODEL" "$TENANT_NS" "$(jq -n --arg ns "$TENANT_NS" --arg model "$OPENAI_MODEL" \
  '{apiVersion:"maas.opendatahub.io/v1alpha1",kind:"MaaSModelRef",metadata:{name:$model,namespace:$ns},spec:{modelRef:{kind:"ExternalModel",name:"openai-model"}}}')"
apply_resource maassubscriptions.maas.opendatahub.io praxis-demo "$TENANT_NS" "$(jq -n --arg ns "$TENANT_NS" --arg model "$OPENAI_MODEL" --arg user "$DEMO_USER" \
  '{apiVersion:"maas.opendatahub.io/v1alpha1",kind:"MaaSSubscription",metadata:{name:"praxis-demo",namespace:$ns},spec:{owner:{users:[$user]},modelRefs:[{name:$model,namespace:$ns,tokenRateLimits:[{limit:10000,window:"1m"}]}],priority:10}}')"
apply_resource maasauthpolicies.maas.opendatahub.io praxis-demo "$TENANT_NS" "$(jq -n --arg ns "$TENANT_NS" --arg model "$OPENAI_MODEL" --arg user "$DEMO_USER" \
  '{apiVersion:"maas.opendatahub.io/v1alpha1",kind:"MaaSAuthPolicy",metadata:{name:"praxis-demo",namespace:$ns},spec:{modelRefs:[{name:$model,namespace:$ns}],subjects:{users:[$user]}}}')"
for item in externalproviders.inference.opendatahub.io/openai externalmodels.inference.opendatahub.io/openai-model; do
  "${OC[@]}" wait "$item" -n "$TENANT_NS" --for=jsonpath='{.status.phase}'=Ready --timeout="$WAIT_TIMEOUT"
done
# MaaS endpoint discovery otherwise falls back to its controller-wide Gateway.
HOST=$("${OC[@]}" get gateway "$GATEWAY" -n "$GW_NS" -o json | jq -er '[.status.addresses[] | select(.type == "Hostname") | .value] | first | select(length > 0)')
HTTP_ROUTE=$("${OC[@]}" get externalmodels.inference.opendatahub.io openai-model -n "$TENANT_NS" -o json | jq -er '.status.httpRouteName | strings | select(length > 0)')
"${OC[@]}" patch httproute "$HTTP_ROUTE" -n "$TENANT_NS" --field-manager="$OWNER" --type=merge \
  -p "$(jq -nc --arg host "$HOST" '{spec:{hostnames:[$host]}}')"
# Keep MaaS API paths in the model's hostname-specific virtual host.
API_ROUTE=$("${OC[@]}" get httproutes -n "$INFRA_NS" -l "app.kubernetes.io/name=maas-api,maas.opendatahub.io/tenant-name=$TENANT_NAME" -o json | \
  jq -er --arg gateway "$GATEWAY" --arg ns "$GW_NS" \
    '[.items[] | select(any(.spec.parentRefs[]; .name == $gateway and .namespace == $ns and (.kind // "Gateway") == "Gateway" and (.group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io"))] | select(length == 1) | .[0].metadata.name') || fail 'Expected one tenant MaaS API route attached to the demo Gateway'
"${OC[@]}" patch httproute "$API_ROUTE" -n "$INFRA_NS" --field-manager="$OWNER" --type=merge \
  -p "$(jq -nc --arg host "$HOST" '{spec:{hostnames:[$host]}}')"
"${OC[@]}" wait "maasmodelrefs.maas.opendatahub.io/$OPENAI_MODEL" -n "$TENANT_NS" \
  --for=jsonpath='{.status.phase}'=Ready --timeout="$WAIT_TIMEOUT"
for item in maassubscriptions.maas.opendatahub.io/praxis-demo maasauthpolicies.maas.opendatahub.io/praxis-demo; do
  "${OC[@]}" wait "$item" -n "$TENANT_NS" --for=jsonpath='{.status.phase}'=Active --timeout="$WAIT_TIMEOUT"
done
"${OC[@]}" rollout status deployment/"payload-processing-external-model-$TENANT_NAME" -n "$TENANT_NS" --timeout="$WAIT_TIMEOUT"
URL="https://$HOST/$TENANT_NS/$OPENAI_MODEL/v1/chat/completions"
echo "Praxis tenant: $AITENANT_NS/$TENANT_NAME"
echo "Chat endpoint: $URL"
echo 'Run ./praxis_mode/test.sh to test inference.'
