# Praxis ExternalModel MVP

This flow tests the RHOAI 3.6 Praxis ExternalModel integration without changing
the existing OGXServer or its Helm releases.

For a cold run, use `cleanup-all.sh`, then reinstall with `./setup.sh` and
`./provision.sh` before running the commands below.

```bash
export LITEMAAS_API_KEY="$(ls-secrets LITEMAAS_API_KEY)"
podman login quay.io
./praxis-mvp/build-images.sh
./praxis-mvp/create-workload.sh
./praxis-mvp/test.sh
```

`build-images.sh` always uses unique Quay tags and refuses a tag that already
exists. It builds the AI Gateway controller, MaaS controller, and OGX Kubernetes
operator images. It also checks out the AI Gateway operator for the manifests
applied by `create-workload.sh`. Override a source revision with
`CONTROLLER_REF`, `MAAS_REF`, `AI_GATEWAY_OPERATOR_REF`, or
`OGX_K8S_OPERATOR_REF`.

The dataplane ExtProc is the RHOAI-supplied image by default. To test local
`opendatahub-io/praxis-extproc` changes, pass `--build-extproc` (or set
`PRAXIS_MVP_BUILD_EXTPROC=true`): the script then builds that repository, pins
the AI Gateway controller's `--image` to the result, and records it in
`images.env` as `PRAXIS_EXTPROC_IMAGE`. Override its revision with
`PRAXIS_EXTPROC_REF`.

Images go to your own registry namespace: by default
`quay.io/<your quay login>/praxis-mvp`, using the account you logged in to with
`podman login quay.io`. That repository must exist and be writable by you.
Override the pieces with `PRAXIS_MVP_REGISTRY_HOST`,
`PRAXIS_MVP_REGISTRY_NAMESPACE`, and `PRAXIS_MVP_REGISTRY_REPOSITORY`, or set
the whole untagged repository at once:

```bash
PRAXIS_MVP_REGISTRY=quay.io/yourname/imagehost ./praxis-mvp/build-images.sh
```

The workload opts the default MaaS tenant into Praxis and adds a LiteMaaS
ExternalProvider for `Qwen2.5-VL-7B-Instruct`. A second tenant is not used
because multi-tenant MaaS callback routing remains unqualified. The test
verifies authenticated LiteMaaS routing using `Qwen2.5-VL-7B-Instruct`,
unknown-model handling, Praxis payload processing, and preservation and
availability of the pre-existing OGXServer.

A second, optional ExternalProvider points straight at OpenAI. It is created only
when `PRAXIS_MVP_OPENAI_API_KEY` or `OPENAI_API_KEY` is set; otherwise
`create-workload.sh` prints a skip line and `test.sh` runs the LiteMaaS checks
alone. When it is configured, both models share the `praxis-mvp` subscription and
auth policy, so the single MaaS API key `test.sh` issues covers both routes.
Override the endpoint with `PRAXIS_MVP_OPENAI_ENDPOINT` (default `api.openai.com`)
and the provider model with `PRAXIS_MVP_OPENAI_MODEL` (default `gpt-4o-mini`).

```bash
OPENAI_API_KEY=sk-... ./praxis-mvp/create-workload.sh
./praxis-mvp/test.sh
```

The client-facing model name currently matches the LiteMaaS provider model.
`MODEL_TRANSLATION_BUG.md` tracks the missing `targetModel` translation needed
to restore a stable MaaS alias.

The cleanup is intentionally destructive:

```bash
./praxis-mvp/cleanup-all.sh --confirm-delete-all
```

It removes OGX, AI Gateway, RHOAI, Kyverno, RHCL/cert-manager operands, test
resources, and related CRDs so the cluster can be reinstalled from scratch.
