# OGX Showroom,

Reference architecture and CI for [OGX](https://github.com/ogx-ai/ogx) on Red Hat OpenShift AI (RHOAI).

## Status

**Work in Progress** - This repository is actively evolving toward a production-ready reference architecture for OGX on RHOAI. While core functionality is operational (deployment, authentication, RAG demos), we're continuously expanding components, refining Helm charts, and adding demo scripts to showcase OGX capabilities in action.

## Purpose

1. **Reference Architecture**: Production-ready deployment of OGX using RHOAI components (VLLM, PostgreSQL, Milvus, Keycloak)
2. **Automated Testing**: CI that validates deployments with example client scripts
3. **Integration Testing**: Test RHOAI/ODH/upstream OGX images through GitHub Actions
4. **Demo Scripts**: Reusable examples (RAG, authentication) for downstream projects

> **Note**: Documentation is intentionally kept minimal during early development to avoid rapid obsolescence. Use LLMs to explore the codebase and understand usage patterns.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│ OGX Distribution (CRD)                               │
│  ├─ Inference: VLLM (llama-3-2-3b)                  │
│  ├─ Embeddings: VLLM (nomic-embed-text-v1.5)        │
│  ├─ Auth: Keycloak OAuth2 (RBAC + Team-based)       │
│  ├─ Vector Store: Milvus (10Gi)                     │
│  ├─ Storage: PostgreSQL (5Gi)                       │
│  └─ Telemetry: OTEL -> Prometheus/Grafana + Jaeger  │
└─────────────────────────────────────────────────────┘
```

**CI/CD**: GitHub Actions workflow tests full deployment lifecycle on ROSA with configurable image overrides for testing ODH/upstream builds.

## Prerequisites

- OpenShift CLI (`oc`)
- Container tool (`podman` or `docker`)
- Python 3.12+
- [uv](https://docs.astral.sh/uv/)

## Cluster Requirements

An OpenShift cluster with the RHOAI operator installed (see `setup.sh`).

Recommended minimum: **3 worker nodes, each 4 vCPU / 32 GiB** (e.g. AWS `m5.xlarge`).
Three nodes - it tolerates one node going NotReady without losing schedulability.
Inference/embeddings are external (OpenAI-compatible), so no GPU is required.

Resource budget:

| Consumer | CPU requests | Memory requests | Storage |
|----------|--------------|-----------------|---------|
| OGX stack (these charts) | ~2 cores | ~5 GiB | 45 Gi (PVCs) |
| RHOAI operator + OpenShift platform | ~5 cores | ~19 GiB | - |

The OGX stack is small; most of the budget is RHOAI/OpenShift platform overhead.
CPU **requests** (reservations), not usage, are what gate scheduling.

## Helm Charts

Pre-built Helm charts are published to `oci://quay.io/opendatahub/ogx-showroom-{infra,rhoai}`. See the [Helm Getting Started](docs/helm-getting-started.md) guide for standalone installation without cloning this repo.

## Setup (from source)

Create local config file (see `values-local.yaml.example` for details):
```bash
cp values-local.yaml.example values-local.yaml
# Edit values-local.yaml and set required values
```

```bash
./setup.sh       # Install RHOAI operator and dependencies
./provision.sh   # Deploy OGX distribution
```

## Run Demos

After provisioning, credentials are read directly from K8s secrets at runtime:

```bash
# Run demos by tags (see demos/manifest.yaml for available tags)
./test.sh              # Run all demos
./test.sh simple       # Run simple demos only
./test.sh complex      # Run complex demos (requires OpenAI API key)
./test.sh rag,api      # Run demos tagged with 'rag' OR 'api'

# Available tags: simple, complex, rag, api, agents, storage, embeddings, openai-required
```

Or run individual demos directly:
```bash
uv run demos/rag/demo.py              # RAG with S3 file storage and vector search
uv run demos/responses/demo.py        # Multi-turn conversations with response tracking
uv run demos/responses/demo.py --prompt "What is RAG?"  # Single-turn with custom question
./demos/tests/restarttest/restarttest.sh  # Test response persistence across server restarts (requires `oc` cluster access)
uv run demos/multi_agent/demo.py      # Multi-agent research assistant
uv run demos/telemetry/demo.py        # Query OGX metrics from Grafana
```

With explicit parameters:
```bash
uv run demos/rag/demo.py <OGX_URL> <KEYCLOAK_URL> <USERNAME> <PASSWORD>
uv run demos/responses/demo.py <OGX_URL> <KEYCLOAK_URL> <USERNAME> <PASSWORD>
```

**Note**: The multi-agent demo requires `ogx.openaiApiKey` to be set in `values-local.yaml`.

### Grafana Dashboard

The deployment includes a Grafana instance with a pre-loaded OGX Overview dashboard showing request rates, latency percentiles, error rates, and inference throughput.

Grafana is exposed via an OpenShift Route (TLS edge) and requires admin login. To get the password:
```bash
oc get secret grafana-secret -o jsonpath='{.data.GRAFANA_ADMIN_PASSWORD}' | base64 -d
```

The dashboard is at `/d/ogx-overview/ogx-overview` on the Grafana route.

### Distributed Tracing (Jaeger)

Jaeger provides end-to-end distributed trace visualization. OGX auto-instruments FastAPI, httpx, SQLAlchemy, and OpenAI SDK calls when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. Traces flow through the OTEL Collector to Jaeger.

Access the Jaeger UI via port-forwarding (no route is exposed):
```bash
oc port-forward svc/jaeger 16686:16686
# Then open http://localhost:16686
```

### Jupyter Notebooks

Run notebook demos in test mode:
```bash
./test.sh jupyter         # Run all Jupyter notebooks
./test.sh hello,jupyter   # Run notebooks tagged with 'hello' and 'jupyter'
```

Run interactively in your browser:
```bash
./demos/notebooks/start_notebook.sh
# Opens browser at http://localhost:8888
# Run cells with Shift+Enter
```

Available notebooks in `demos/notebooks/`:
- `hello.ipynb` - Simple chat completion with authentication
- `rag_indexing.ipynb` - Build RAG index from PDFs using Milvus vector store
- `rag_inference.ipynb` - Retrieval-augmented generation with question answering

## Deploy Local Changes

Test local OGX code changes on the cluster for rapid iteration.

### Quick Start

```bash
# 1. Clone ogx locally
git clone https://github.com/ogx-ai/ogx ~/ogx

# 2. Configure (add to values-local.yaml)
#    devLocal:
#      ogxSourcePath: ~/ogx

# 3. Deploy your changes
./deploy-local.sh
# → Builds image, pushes to in-cluster registry, restarts pod, shows logs

# 4. Test your changes
curl https://$(oc get route ogx-distribution -o jsonpath='{.spec.host}')/v1/health

# 5. Revert to official image when done
./provision.sh
```

**Features**: Uses in-cluster registry (no external accounts needed), auto-detects base image and handles authentication.

### Configuration

Add to `values-local.yaml` under `devLocal:` (see `values-local.yaml.example`):

| Key | Default | Description |
|-----|---------|-------------|
| `devLocal.ogxSourcePath` | *(required)* | Path to local OGX source repository |
| `devLocal.imageNamespace` | `redhat-ods-applications` | Namespace for images |
| `devLocal.imageName` | `ogx-dev` | Image name |
| `devLocal.imageTag` | `dev-YYYYMMDD-HHMMSS` | Image tag (auto-generated) |
| `devLocal.baseImage` | *(auto-detected)* | Base image to use |
| `devLocal.containerTool` | `podman` | Container tool (podman/docker) |

### Troubleshooting

**Registry authentication fails**:
```bash
REGISTRY=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
podman login -u $(oc whoami) -p $(oc whoami -t) --tls-verify=false $REGISTRY
```

**Registry route not available** (requires cluster-admin):
```bash
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type=merge -p '{"spec":{"defaultRoute":true}}'
```

**Pod not using dev image**:
```bash
# Check Kyverno policy exists
oc get clusterpolicy replace-rhoai-ogx-images

# Check pod image
oc get pod -l app=ogx -n redhat-ods-applications \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

## Cleanup

```bash
./unprovision.sh  # Remove OGX distribution
./cleanup.sh      # Remove RHOAI operator and dependencies
```

## Testing

CI workflow (`.github/workflows/provision.yml`) runs on PRs and supports image overrides:
- `catalog_image`: Custom RHOAI catalog source
- `ogx_image`: Custom OGX distro image
- `operator_image`: Custom operator image

This enables testing ODH/upstream builds before they're released.

## Contributing

Contributions welcome in:
- Additional demo scripts
- Helm chart improvements and new subcharts
- CI/CD improvements and test coverage
