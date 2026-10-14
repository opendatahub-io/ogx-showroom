# Praxis demo status and PR plan

Updated: 2026-10-14.

For prerequisites, deployment and demo commands, see [README.md](README.md).

## Current position

- The demo uses AITenant `praxis-demo`, OpenAI ExternalProvider/ExternalModel
  `openai` / `openai-model`, model `gpt-6-luna` and a dedicated Praxis Gateway.
- Chat Completions, native non-streaming Responses persistence and Conversations
  state operations have passed live tests against dedicated PostgreSQL storage.
- The live two-turn `previous_response_id` chain passed on the rebased images,
  including retrieval, original input-items and local deletion. The outbound
  rewrite and controller append-back fixes are deployed and pass local two-turn
  tests. Conversation-backed inference remains unqualified live; the script only
  creates and deletes a Conversation.
- Responses is enabled with `PlatformDefault` / `Retain`, without `maxAge`.
  Native SSE persistence and live packaged PostgreSQL restart durability remain
  unqualified. This is a custom development integration, not a packaged-product
  or FIPS compliance claim.
- The shared-platform binding implementation is deployed. The existing platform
  binding/runtime projection were already in use before this rollout; no database
  cutover, owner migration or existing-data disposal was performed. Responses
  storage remains separate from MaaS API-key storage.
- MaaS integration commits are signed off and pushed to the `derekhiggins` fork
  on `feat/tenant-responses-state-apis`; [PR #1668](https://github.com/opendatahub-io/models-as-a-service/pull/1668)
  is open. Praxis AI planner `23df61cc` is pushed to the `derekhiggins/praxis-ai`
  fork on `feat/shared-offline-store-planner`; [PR #1690](https://github.com/praxis-proxy/ai/pull/1690)
  is open. ExtProc's six commits are pushed to the `derekhiggins/praxis-extproc`
  fork on `feat/tenant-responses-storage`; [draft PR #152](https://github.com/opendatahub-io/praxis-extproc/pull/152)
  is open. Controller branches are pushed to the `derekhiggins` fork:
  [isolation PR #132](https://github.com/opendatahub-io/ai-gateway-controller/pull/132)
  and [Responses draft #133](https://github.com/opendatahub-io/ai-gateway-controller/pull/133)
  are open. The optional startup fix remains local.
  ExtProc has uncommitted
  core 0.7.4 dependency/context compatibility
  changes alongside temporary Cargo patches/lockfile changes and Containerfile
  wiring. The other source checkouts are clean.
  All four branches include their fetched origin/main.

## Commit and PR plan

### MaaS: required integration PR

Source: `praxis_mode/src/models-as-a-service`.

| Commit | Purpose |
| --- | --- |
| `e27d96d5` | Add AITenant Responses enablement and storage configuration |
| `25fec6ee` | Exempt authenticated state operations from fallback inference token limits |

These two commits are submitted together in PR #1668. Hold `54b7e235`
(resolved-Gateway endpoint discovery) for a separate later PR; it is unrelated
to the integration PR.
The endpoint fix has been removed from the local MaaS integration branch.
The demo retains explicit route-hostname workarounds and does not require that
fix for the planned integration. The fix is already in the recorded deployed
MaaS image; holding back its PR does not mean reverting the live image.

### Praxis AI: required planner PR and separate optional startup PR

Source: `praxis_mode/src/praxis-ai`.

| Commit | Plan | Purpose |
| --- | --- | --- |
| `23df61cc` | Required PR | Share offline store planning across serving transports |
| `67b550fc` | Separate optional PR | Serialize shared PostgreSQL schema startup and roll back failed initialization |

ExtProc bootstrap depends on the planner, not the startup fix. Omitting the
startup fix requires no caller changes, but leaves concurrent schema creation
races and partial initialization after failures possible.
Planner PR #1690 contains only `23df61cc`; `67b550fc` is not submitted.

### AI Gateway controller

Source: `praxis_mode/src/ai-gateway-controller`.

| Commit | Purpose |
| --- | --- |
| `802e610` | Independently isolate ExternalModel ExtProc network access |
| `6643d37` | Configure tenant Responses/Conversations APIs with platform storage |

Keep these logical boundaries. The API integration preserves the preceding
NetworkPolicy work and presents the final storage contract directly. It is not
a breaking change from a released Responses storage contract.
The NetworkPolicy change also restricts Responses-disabled ExternalModel chat;
retain that compatibility warning.
PR #132 contains only `802e610`. Draft #133 targets main and includes both
commits until #132 merges and it is rebased. Its temporary 773-production-line
diff exceeds the 750-line cap; the Responses-only diff is 723 lines. No size
exception is requested. Runtime prerequisites are MaaS #1668, ExtProc #152 and
Praxis AI #1690, plus installed schema/RBAC and platform storage bindings.

### Praxis ExtProc

Source: `praxis_mode/src/praxis-extproc`. Local commits in order on `653ccff`
(origin/main, including upstream PR #147):

| Commit | Purpose |
| --- | --- |
| `83e0475` | Enable Conversations in the release profile |
| `94045bc` | Preserve request extensions across processing phases |
| `f7bad77` | Persist complete stored Responses JSON before releasing success |
| `1254666` | Initialize stores before readiness and drain backend leases |
| `ed49c06` | Load database URLs from mounted Secret files |
| `6ed8c9a` | Run outbound body hooks for local history replay, including two-turn controller regression and UID fixture coverage |

All six are submitted in draft PR #152 and needed for the complete integration.
Keep the functional commits separate; the outbound fix already includes its test
follow-ups. The draft is blocked on Praxis AI #1690 and dependency updates;
local adapter compatibility and build wiring are excluded.
PR #147 is upstream; do not resubmit its former cherry-pick.
Use a semantic title for the Conversations commit before submission.

### Dependency and submission gates

1. Validate each PR against its target branch and upstream CI.
2. Merge the required Praxis AI planner before merging ExtProc bootstrap.
   Update ExtProc's Praxis AI dependency references and Cargo.lock to a revision
   containing the planner. Unmodified v0.6.0 lacks `praxis_ai_apis::store::plan`;
   the committed bootstrap cannot build standalone against that pin.
   Include ExtProc's pending core 0.7.4 dependency/context compatibility changes;
   its local lockfile now matches the rebased Praxis AI requirement.
3. Remove temporary sibling-path Cargo patches and container archive wiring when
   the upstream dependency is available. The optional PostgreSQL startup fix is
   not a merge/build prerequisite.
4. Make the controller's MaaS schema/token-policy and ExtProc feature/fix
   dependencies explicit. Prepare the API integration with the full runtime
   prerequisites, not an image-only deployment assumption.
5. Keep unrelated showroom work and the held-back MaaS endpoint fix out of the
   integration submissions. No rollout or paid validation is part of PR preparation.

## Implementation contracts

### API, routing and ownership

- `AITenant.spec.responses.enabled` defaults false and opts into Responses and
  Conversations together. Only `PlatformDefault` / `Retain` without `maxAge` is
  served. Unsupported settings withdraw API routes and any old stateful workload;
  no retention worker is implemented.
- Standard `/v1/responses` and `/v1/conversations` use the dedicated tenant
  Gateway and inherited MaaS authentication. Responses POST uses existing model
  subscription token policies; Conversations GET/POST/DELETE and stored Responses
  GET/DELETE, including input-items, bypass only the fallback token limit.
  Unsupported methods and inference remain subject to limits.
- State-operation routes use endpoint-free fail-closed sinks. Model-prefixed chat
  rules remain unchanged; existing model-route hostname overrides are reused.
- Ownership is AITenant UID, issuer `urn:maas:authorino` and trusted
  `X-MaaS-Username`. Client-forged identity headers must be rejected. Usernames are
  not immutable subjects; identity changes need an ownership review.
- Generated filters use flat conditions so body hooks run with the pinned core.
  Conversations state operations and Responses append-back use separate entries,
  sharing storage; multiple path conditions in one entry would be ANDed.

### Shared platform storage and runtime

- Infrastructure `responses-db-config` contains `DB_CONNECTION_URL`, `tls.crt`
  and `tls.key`; `responses-db-ca` contains `ca.crt`. Keep certificate-only
  authentication and storage separate from MaaS API keys. The [proposal][responses-proposal]
  defines URL/CA conventions but not client-certificate keys; call out placement
  during review.
- The controller reads bindings directly without caching credential values and
  projects only those four keys into private `responses-runtime-<tenant>` Secrets.
  Foreign projections, known MaaS database reuse and URL query overrides other
  than `sslmode` are rejected. Source revisions trigger enabled-tenant rollout.
- Endpoint/database changes require explicit cutover. The private projection is
  retained on disablement as a database-identity fence and deleted on tenant
  cleanup; platform Secrets and database are never removed by that cleanup.
- A same-image init container copies the PKCS#8 client key into memory-backed
  storage as the serving UID with mode 0600. The serving container mounts the
  copy read-only. PostgreSQL uses `verify-full` and client certificates.
- Store discovery/normalization/sharing/collision checks use the shared planner.
  ExtProc validates strictly; the Praxis server retains its permissive discovery
  behavior and existing lifecycle handling. Each shared backend pool is limited
  to two connections with a ten-second acquire timeout. Size storage for tenants,
  replicas and rollout overlap.
- Store provisioning runs on the serving runtime before the ExtProc listener
  opens or named gRPC readiness reports Serving. Failure remains NotServing;
  leases retire after serving and request-held pipeline references drain.
  Validation remains offline, except that URL-file validation reads the file.
- URL files contain one literal UTF-8 URL, bounded to 16 KiB. Missing, empty,
  oversized or ambiguous sources fail closed; URL contents are not printed or
  embedded in ConfigMaps. There is no environment/YAML interpolation.
- Enabled Responses shares its ExternalModel ExtProc workload with chat, so
  storage initialization/contract failures also block that chat path.
- ExternalModel ExtProc gets a dedicated NetworkPolicy: only its resolved Gateway
  on 9004, monitoring on 9090 and DNS/PostgreSQL egress. Shared policies exclude
  it. Isolation remains while pods drain and ends at tenant cleanup.
  `--skip-network-policy` requires equivalent installation-supplied networking;
  other additive policies can widen access.
- Optional `67b550fc` performs DDL, validation and version stamping in one
  transaction under a per-schema advisory lock with a 30-second lock timeout.
  This coordinates startup; it is not a versioned migration runner.

### ExtProc transport boundaries

- Release features are `responses,aws-sigv4,store-postgres-cert-auth,conversations`.
  SQLite, password-authenticated PostgreSQL, tools, compaction and policy engine
  are not added to the release profile. Dependency checks are not FIPS certification.
- Request extensions preserve ownership, original input and store state across
  phases; debug output omits their contents.
- Successful stored non-streaming Responses JSON gets a response-header BUFFERED
  override so the complete body is persisted before release. Accumulation is
  bounded by 64 MiB or the lower server limit; Envoy/gRPC limits may be lower.
  SSE, `store:false`, upstream errors and Chat Completions retain their transport.
- Envoy must allow mode overrides, set
  `send_body_without_waiting_for_header_response: false` and fail closed on
  ExtProc errors. Eager/partial delivery after the override is rejected.
- Accumulated BUFFERED/FULL_DUPLEX_STREAMED requests run outbound body hooks after
  ordinary filters, consuming local selectors and forwarding rehydrated history
  without replacing original-input capture. Rejections/errors withhold the body.
  Chunk-at-a-time STREAMED requests do not support this final rewrite; Envoy owns
  routing and no selected provider/protocol identity is synthesized.

## Sources and recorded deployment

Build from the independent checkouts under `praxis_mode/src/`.
The sibling `/home/dhiggins/workarea/ai-gateway-controller` is not the default
source and must not be modified or discarded.

Deployed digests in `quay.io/higginsd/imagehost`, verified on 2026-10-14:

| Component | Digest |
| --- | --- |
| AI Gateway controller | `sha256:d62ef788777d57c87eebce36f1fedf8da4c060920b943e9a6f4d7b5e154d7577` |
| MaaS controller | `sha256:7285d8d6ef0742dd839331eb2b1e62a97873a8105ff4390c5c2743afbcc00325` |
| Praxis ExtProc | `sha256:9bedfadb93c9fd58ec5f07e4aaf9753c500f4e04ab3ef14975aad8b7aa9ec59a` |

The ExtProc image includes the local planner, optional startup fix, bootstrap,
URL loading, native capture, outbound rewrite and uncommitted core 0.7.4
compatibility changes. Controller append-back/shared bindings and MaaS endpoint
discovery fix `54b7e235` are deployed; the endpoint fix remains held back from the
integration PR plan. Both controllers and the tenant ExtProc pod were Ready with
zero restarts after setup/live tests.

Operational resources:

- AITenant `ai-tenants/praxis-demo`; tenant namespace `ai-tenant-praxis-demo`.
- Gateway `openshift-ingress/praxis-demo-gateway`, separate from OGX's Gateway.
- Tenant routes `external-model-openai-model` and `responses-api-praxis-demo`.
- Tenant ExtProc `payload-processing-external-model-praxis-demo`; Gateway-local
  `payload-pre-processing-praxis-demo` and `payload-processing-praxis-demo`.
- MaaS API/databases in `redhat-ai-gateway-infra`; Responses PostgreSQL
  `responses-postgres-praxis-demo`, separate from `maas-postgres`.

Temporary ExtProc builds patch Praxis AI to `praxis_mode/src/praxis-ai`, archive
that checkout and unpack it at `/praxis-ai`. `PRAXIS_AI_SOURCE_DIR` overrides the
source; standalone modified Containerfile builds require `praxis-ai.tar`.
Remove this wiring for the merged upstream dependency.

## Demo operation and packaging constraints

- Explicit platform preparation is `setup.sh --provision-responses-storage`.
  It reuses `responses-postgres-praxis-demo` independently of `TENANT_NAME`,
  verifies mTLS before publishing split bindings and restricts ingress to
  ExternalModel ExtProc pods marked with a Responses tenant UID. Ordinary tenant
  setup validates existing bindings. Conflicts or invalid credentials stop setup.
- Certificates are reused, not automatically rotated: CA lifetime ten years,
  server/client lifetime one year. Network login requires verified TLS and client
  certificates for role `responses`; local administration uses peer authentication.
  MaaS API-key storage remains cluster-internal plaintext with a demo-specific
  egress policy selecting `app=maas-postgres`.
- Setup keeps model and MaaS API routes on the same Gateway hostname; the derived
  Responses route must match too. Retiring hostname workarounds requires clearing
  all three consistently. The endpoint-discovery fix alone does not resolve mixed
  virtual-host routing; paid hostname-free inference is untested.
- The demo Authorino EnvoyFilter supplies verified service-CA TLS, SNI, exact DNS
  SAN verification and HTTP/2 to Kuadrant's custom auth cluster. It selects only
  the demo Gateway. Priority -10 ADD precedes Kuadrant's ADD; duplicate-cluster
  metrics may result. Do not enable KServe solely to replace this workaround.
- Keep the tenant model-finalizer Role/Binding and the supplemental MaaS
  InferenceObjective read grant until packaged operators include upstream fixes.
  The latter is cluster-wide and not automated by setup/cleanup. Operator updates
  are deferred; do not hand-patch shared operator-owned roles as a durable fix.
- Both cleanup modes retain shared Responses storage, certificates and bindings.
  `--full` purges only owned MaaS storage after confirmation, ownership/consumer
  checks and finalizer completion. Never force finalizers. Shared platform state
  and image policies remain; cleanup is not a platform restoration.
- `build-deploy.sh` builds disposable source copies and applies pushed image
  digests through pod-only Kyverno overrides. Controller replacement affects all
  tenants; ExtProc replacement is demo-scoped. Admission and readiness are checked.
- MaaS deployment narrowly patches the Responses schema and sets
  `opendatahub.io/managed=false` on the AITenant CRD. This blocks packaged updates
  to the entire CRD until management is explicitly restored after packaged support
  exists. Image swaps do not install schema/RBAC changes.
- `test.sh` uses an authenticated admin and a temporary MaaS key. A successful run
  makes three paid requests: chat and two linked Responses. It retrieves state,
  creates a Conversation without Conversation-backed inference and cleans up its
  records, key, port-forward and files. It is not a readiness/security/SSE/durability
  qualification harness. Run it only when requested.

## Validation and limits

- Current rebased image builds and rollouts, ordinary `setup.sh` and `test.sh`
  passed. The live script made three paid requests and cleaned up its local
  Responses, Conversation and temporary MaaS key. It does not qualify
  Conversation-backed inference, native SSE persistence or database restart.
- Current rebased controller passes race tests, full envtest and lint. MaaS
  API/schema and tenant-policy race tests pass. Praxis AI passes 14 planner and
  19 server store-provisioning tests. ExtProc full/release-profile tests, release
  Clippy, nightly formatting and the controller-generated two-turn fixture pass
  with the local core 0.7.4 compatibility changes and sibling Praxis AI patches.
- Live native JSON create/retrieval/input-items/deletion and foreign-owner denial
  passed. Conversations state operations and foreign-owner denial passed.
  Unauthenticated requests were rejected; forged username and unsubscribed
  Responses creation were denied. Test records/keys were cleaned up.
- Packaged PostgreSQL mTLS/key-permission checks and selected Gateway/database
  isolation probes passed. These are selected paths, not exhaustive enforcement.
- Local ExtProc full/release tests, Clippy, nightly formatting and whitespace
  checks passed with local Praxis AI. Controller-generated two-turn tests cover
  append-once behavior, replay, original input and foreign ownership using SQLite
  and controlled completions, not paid inference. The squash/message rewrites
  preserved code; tests were not rerun for message-only changes.
- Both controller logical commits independently passed `go test -race ./...`,
  full envtest, formatting and lint. MaaS API/policy race tests, codegen and
  manifest validation passed. MaaS endpoint-fix validation also passed, but full
  lint reported existing issues in `aitenant_validation_test.go` and
  `postrender_test.go`.
- Planner API/server tests, Clippy and rustdoc passed. Backend preparation passed
  191 routine tests and three disposable PostgreSQL tests for concurrent startup,
  rollback and ownership. Certificate-only bootstrap/TLS/identity/restart tests
  used cached PostgreSQL 16, not the packaged OpenShift server. Database tests and
  the controller fixture are ignored in routine runs and need explicit execution.
- Local Envoy with SQLite/mock upstream passed chunked JSON capture, ownership,
  deletion and fail-closed storage errors; SSE bytes arrived before EOS. This
  verifies streaming transport, not native SSE persistence.
- Script syntax/ShellCheck, shared provisioning/cleanup mocks, curl-script mocks
  and build/deploy mocks passed. Exact upstream target-branch CI remains outstanding.

Useful local evidence and fixtures:

- `/tmp/opencode/praxis-prep-{controller-tests,controller-envtest,controller-lint,store-tests,store-clippy,store-cert-clippy,postgres-tests,extproc-fixture,scripts,scripts-mtls}.log`.
- `/tmp/opencode/controller-split-{network,responses}-{unit,envtest,format,lint}.log`.
- `/tmp/opencode/controller-typed-{unit,envtest,lint}.log` and
  `/tmp/opencode/controller-typed-network-{unit,envtest,format,lint}.log`.
- `/tmp/opencode/controller-origin-rebase-{unit,envtest,lint}.log`,
  `/tmp/opencode/maas-origin-rebase-tests.log`,
  `/tmp/opencode/planner-origin-rebase-{tests,server-tests}.log` and
  `/tmp/opencode/extproc-origin-rebase-tests.log`.
- `/tmp/opencode/praxis-final-{controller,maas,extproc}-build-deploy.log`,
  `/tmp/opencode/praxis-final-{setup,live-test}.log`,
  `/tmp/opencode/extproc-final-{full-tests,release-profile-tests,release-clippy,format}.log`
  and `/tmp/opencode/praxis-final-controller-extproc-fixture.log`.
- `/tmp/opencode/praxis-ai-planner-pr-{full-tests,clippy,minimal,cert-profile,format,rustdoc}.log`
  validates planner `23df61cc` independently, without the optional startup fix.
- `/tmp/opencode/controller-network-pr-{unit,envtest,format,lint}.log` validates
  isolation `802e610` independently; lint uses a fresh worktree-specific cache.
- `/tmp/opencode/praxis-chain-live.log` for the partial live chain test.
- `/tmp/opencode/test-praxis-native-capture-envoy.py` and
  `/tmp/opencode/test-praxis-postgres-mtls.py` for local transport/mTLS checks.
  Use fresh disposable bindings, never tenant data, for database test harnesses.
- Regenerate the ignored controller fixture from
  `TestResponsesConfigAndMountsRemainTenantLocal` with `PRAXIS_TEST_CONFIG_OUT`;
  supply it to Rust with `PRAXIS_TEST_CONTROLLER_CONFIG`.

## Remaining work

1. Track submitted PR CI and reviews. After controller isolation #132 merges,
   rebase Responses draft #133 to remove the prerequisite from its diff and
   satisfy the size cap. Keep runtime and packaging dependencies explicit.
2. Prepare ExtProc's core 0.7.4 dependency/context compatibility changes as a
   source commit, keeping temporary sibling Cargo patches and container wiring
   out of submissions. The runtime projection/RBAC and infrastructure binding
   are present; no database migration or tenant-local binding removal is needed
   for the current rollout.
3. Qualify live Conversation-backed inference separately with approval. Local
   fixtures and the live previous-response chain do not qualify that path.
4. Qualify native SSE persistence, packaged PostgreSQL restart/recovery, broader
   Gateway/database isolation, disable/re-enable/draining and credential/CA rollover.
5. Review proposal gaps: stable principal identity, AITenant `ResponsesReady`,
   readiness-gated route activation, independent chat during stateful outages,
   versioned migrations and retention/tombstones. Shared credentials leave runtime
   or namespace-administrator compromise inside the trust boundary; pod labels
   are not database-enforced tenant isolation.
6. Complete FIPS-host, release binary/scanner and exact-source CI qualification.
   Dependency checks and a successful UBI build are not compliance evidence.
7. Review upstream OpenAI retention/deletion separately from local deletion. The
   unrecovered response `resp_00441adc5729244d006ace0b9d730087d29d0b2d101b5d9d7b`
   has unverified upstream disposition; local DELETE does not prove upstream deletion.
8. Replace the Authorino TLS workaround with supported handling; recheck
   [Kuadrant #1531][kuadrant-tls]. Verify packaged controller/operator permissions
   before removing supplemental RBAC. Review inference CRD status-field warnings,
   AITenant CRD management and any remaining legacy ownership/selector annotations.
9. OGX-backed services and iterative response routing remain future work. Evaluate
   MaaS PR #1561 with companion runtime, CRD and operator requirements. Existing OGX
   resources remain unchanged. Keep unrelated Gateway/monitoring work out of scope.

## Guardrails for resuming

- This status authorizes no rollout, API enablement, schema/RBAC change, database
  migration, restart or purge. Obtain approval for those and for paid requests.
- Check the active kube context before live work. Use fully qualified inference
  resource names: ExternalModel CRDs exist in both `inference.opendatahub.io` and
  `maas.opendatahub.io`.
- Do not edit setup while it is running. Preserve unrelated work and sibling
  checkouts. Never put provider credentials, API keys or database values in docs.
- Both cleanup modes retain shared Responses storage/bindings; `--full` destroys
  only owned MaaS storage after the documented checks.

[responses-proposal]: https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/architecture-internals/proposals/guardrails-responses/02-responses-low-level-details.md#responses-enablement-and-lifecycle
[kuadrant-tls]: https://github.com/Kuadrant/kuadrant-operator/issues/1531
