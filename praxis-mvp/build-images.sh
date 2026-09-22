#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

registry="${PRAXIS_MVP_REGISTRY:-}"
registry_host="${PRAXIS_MVP_REGISTRY_HOST:-quay.io}"
registry_namespace="${PRAXIS_MVP_REGISTRY_NAMESPACE:-}"
registry_repository="${PRAXIS_MVP_REGISTRY_REPOSITORY:-praxis-mvp}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_id="${PRAXIS_MVP_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
run_dir="$script_dir/artifacts/$run_id"
source_dir="$script_dir/src"
engine="${CONTAINER_ENGINE:-podman}"

controller_ref="${CONTROLLER_REF:-main}"
maas_ref="${MAAS_REF:-main}"
operator_ref="${AI_GATEWAY_OPERATOR_REF:-main}"
ogx_operator_ref="${OGX_K8S_OPERATOR_REF:-main}"
praxis_extproc_ref="${PRAXIS_EXTPROC_REF:-main}"
rebase_sources=false
# The dataplane runs the RHOAI-supplied ExtProc image by default. Opt in only to
# test local praxis-extproc changes: it is a from-scratch Rust build.
build_extproc="${PRAXIS_MVP_BUILD_EXTPROC:-false}"

while (($#)); do
  case "$1" in
    --rebase) rebase_sources=true ;;
    --build-extproc) build_extproc=true ;;
    -h|--help) printf 'Usage: %s [--rebase] [--build-extproc]\n' "$0"; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

for command in git "$engine" skopeo oc jq; do
  command -v "$command" >/dev/null || { printf 'ERROR: %s is required\n' "$command" >&2; exit 1; }
done
oc whoami >/dev/null || { printf 'ERROR: log in to OpenShift first\n' >&2; exit 1; }

if [[ -z "$registry" ]]; then
  if [[ -z "$registry_namespace" ]]; then
    registry_namespace="$(skopeo login --get-login "$registry_host" 2>/dev/null || true)"
  fi
  if [[ -z "$registry_namespace" ]]; then
    printf 'ERROR: cannot tell which %s namespace to push to\n' "$registry_host" >&2
    printf 'Run "%s login %s", or set PRAXIS_MVP_REGISTRY_NAMESPACE or PRAXIS_MVP_REGISTRY\n' \
      "$engine" "$registry_host" >&2
    exit 1
  fi
  registry="$registry_host/$registry_namespace/$registry_repository"
fi
[[ "$registry" != *:* || "$registry" == *:*/* ]] || { printf 'ERROR: PRAXIS_MVP_REGISTRY must be a repository without a tag: %s\n' "$registry" >&2; exit 1; }
printf 'Pushing images to %s\n' "$registry" >&2

mkdir -p "$run_dir/src" "$source_dir"

checkout() {
  local repository="$1" ref="$2" directory="$3"
  git init -q "$directory"
  git -C "$directory" remote add origin "$repository"
  git -C "$directory" fetch --quiet origin "$ref"
  git -C "$directory" checkout --quiet --detach FETCH_HEAD
}

rebase_source() {
  local directory="$1" ref="$2"
  if [[ "$(git -C "$directory" rev-parse --is-shallow-repository)" == true ]]; then
    git -C "$directory" fetch --quiet --unshallow origin
  fi
  git -C "$directory" fetch --quiet origin "$ref"
  git -C "$directory" rebase --quiet FETCH_HEAD
}

source_revision() {
  local directory="$1" revision
  revision="$(git -C "$directory" rev-parse HEAD)"
  if [[ -n "$(git -C "$directory" status --porcelain)" ]]; then
    revision+="-dirty"
  fi
  printf '%s' "$revision"
}

prepare_source() {
  local name repository ref directory
  name="$1"
  repository="$2"
  ref="$3"
  directory="$source_dir/$name"
  if [[ ! -d "$directory/.git" ]]; then
    [[ ! -e "$directory" ]] || { printf 'ERROR: %s exists but is not a git checkout\n' "$directory" >&2; exit 1; }
    checkout "$repository" "$ref" "$directory"
  fi
  if [[ "$rebase_sources" == true ]]; then
    rebase_source "$directory" "$ref"
  fi
  source_revision "$directory"
}

build_push() {
  local name="$1" revision="$2" context="$3" containerfile="$4"
  printf "Building %s\n" $name >&2
  local image="$registry:${name}-${revision:0:12}-${run_id}" digest
  if skopeo inspect "docker://$image" >/dev/null 2>&1; then
    printf 'ERROR: refusing pre-existing destination %s\n' "$image" >&2
    exit 1
  fi
  "$engine" build --pull=always --platform linux/amd64 --file "$containerfile" \
    --label "org.opencontainers.image.revision=$revision" --tag "$image" "$context" >&2
  "$engine" push "$image" >&2
  digest="$(skopeo inspect --format '{{.Digest}}' "docker://$image")"
  [[ "$digest" == sha256:* ]] || { printf 'ERROR: no digest for %s\n' "$image" >&2; exit 1; }
  printf '%s@%s' "${image%:*}" "$digest"
}

controller_sha="$(prepare_source controller https://github.com/opendatahub-io/ai-gateway-controller.git "$controller_ref")"
maas_sha="$(prepare_source maas https://github.com/opendatahub-io/models-as-a-service.git "$maas_ref")"
prepare_source operator https://github.com/opendatahub-io/ai-gateway-operator.git "$operator_ref" >/dev/null
ogx_operator_sha="$(prepare_source ogx-operator https://github.com/red-hat-data-services/ogx-k8s-operator.git "$ogx_operator_ref")"
sources=(controller maas operator ogx-operator)
if [[ "$build_extproc" == true ]]; then
  praxis_extproc_sha="$(prepare_source praxis-extproc https://github.com/opendatahub-io/praxis-extproc.git "$praxis_extproc_ref")"
  sources+=(praxis-extproc)
fi

if [[ "${PRAXIS_MVP_PREPARE_SOURCES_ONLY:-false}" == true ]]; then
  printf 'Persistent sources are ready in %s\n' "$source_dir"
  exit 0
fi

controller_image="$(build_push ai-gateway-controller "$controller_sha" "$source_dir/controller" "$source_dir/controller/Dockerfile")"
maas_image="$(build_push maas-controller "$maas_sha" "$source_dir/maas" "$source_dir/maas/maas-controller/Dockerfile")"
ogx_operator_image="$(build_push ogx-k8s-operator "$ogx_operator_sha" "$source_dir/ogx-operator" "$source_dir/ogx-operator/Dockerfile")"
if [[ "$build_extproc" == true ]]; then
  praxis_extproc_image="$(build_push praxis-extproc "$praxis_extproc_sha" "$source_dir/praxis-extproc" "$source_dir/praxis-extproc/Containerfile")"
fi

for name in "${sources[@]}"; do
  cp -a "$source_dir/$name" "$run_dir/src/$name"
done

cat >"$run_dir/images.env" <<EOF
RUN_ID=$run_id
RUN_DIR=$run_dir
CONTROLLER_SHA=$controller_sha
CONTROLLER_IMAGE=$controller_image
MAAS_SHA=$maas_sha
MAAS_IMAGE=$maas_image
OGX_K8S_OPERATOR_SHA=$ogx_operator_sha
OGX_K8S_OPERATOR_IMAGE=$ogx_operator_image
EOF
if [[ "$build_extproc" == true ]]; then
  cat >>"$run_dir/images.env" <<EOF
PRAXIS_EXTPROC_SHA=$praxis_extproc_sha
PRAXIS_EXTPROC_IMAGE=$praxis_extproc_image
EOF
fi
cp "$run_dir/images.env" "$script_dir/artifacts/images.env"

if ! oc get deployment kyverno-admission-controller -n kyverno >/dev/null 2>&1; then
  oc apply --server-side -f https://github.com/kyverno/kyverno/releases/download/v1.12.1/install.yaml
  oc wait --for=condition=available deployment/kyverno-admission-controller -n kyverno --timeout=5m
fi

if [[ "$build_extproc" == true ]]; then
  extproc_image_arg="--image=$praxis_extproc_image"
else
  # Keep the RHOAI-supplied ExtProc image. The backslash escapes $() for Kyverno
  # (legacy variable syntax); kubelet then expands the env var.
  # shellcheck disable=SC2016
  extproc_image_arg='--image=\$(RELATED_IMAGE_ODH_PRAXIS_EXTPROC_IMAGE)'
fi

oc apply -f - <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: praxis-mvp-image-swap
spec:
  background: false
  failurePolicy: Fail
  rules:
  - name: ai-gateway-controller
    match: {any: [{resources: {kinds: [Pod], selector: {matchLabels: {control-plane: ai-gateway-controller}}}}]}
    mutate:
      patchStrategicMerge:
        spec:
          containers:
          - name: manager
            image: "$controller_image"
            args:
            - --leader-elect
            - --health-probe-bind-address=:8081
            - $extproc_image_arg
            - --known-cluster=provider-praxis-mvp-provider-a
            - --known-cluster=provider-praxis-mvp-provider-b
  - name: maas-controller
    match: {any: [{resources: {kinds: [Pod], selector: {matchLabels: {control-plane: maas-controller}}}}]}
    mutate:
      patchStrategicMerge:
        spec:
          containers:
          - name: manager
            image: "$maas_image"
  - name: ogx-k8s-operator
    match: {any: [{resources: {kinds: [Pod], selector: {matchLabels: {app.kubernetes.io/name: ogx-k8s-operator, control-plane: controller-manager}}}}]}
    mutate:
      patchStrategicMerge:
        spec:
          containers:
          - name: manager
            image: "$ogx_operator_image"
EOF
oc wait --for=condition=Ready clusterpolicy/praxis-mvp-image-swap --timeout=2m
printf 'Images and Kyverno policy are ready. State: %s\n' "$run_dir/images.env"
