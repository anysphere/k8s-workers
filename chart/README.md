# k8s-workers Helm Chart

Step-by-step install, any-repo vs repo-bound, and claim vs warm-idle modes:
see the root [README.md](../README.md).

Deploys an in-cluster `agent worker controller` that kubectl-creates Cursor
self-hosted **pool** workers as vanilla Kubernetes **Pods**.

This chart is **additive** to the published operator path:

1. Install [`worker-set-controller-chart`](https://cursor.com/docs/cloud-agent/self-hosted-guides/kubernetes).
2. Apply `WorkerDeployment` resources.

Keep the operator installed if you still need that path.

## What this installs

| Resource | When | Description |
|----------|------|-------------|
| Deployment (1 replica) | `controller.enabled` | `agent worker controller --spawn …` (the controller process) |
| ConfigMap | `controller.enabled` | Spawn hook that `kubectl create`s one worker Pod |
| Role / RoleBinding | `controller.enabled` and `rbac.create` | Namespace permission to create/get/list Pods |
| ServiceAccount | `serviceAccount.create` | Controller SA; token automount on (required for kubectl) |
| Secret | `auth.apiKey` set and `auth.existingSecret` empty | Holds `CURSOR_API_KEY` |

Worker **instances** are outside the Helm release. Each `--spawn` creates a Pod
with `restartPolicy: Never`. Workers authenticate with a team **service account
API key** (`CURSOR_API_KEY`).

The controller image must include the `agent` CLI **and** `kubectl` on `PATH`.
Override `controller.image` when the worker image has `agent` but not `kubectl`.

## Quick start

Your worker image must include the `agent` CLI, `git` on `PATH`, and a
workspace at `workerDir` (see the
[Kubernetes self-hosted guide](https://cursor.com/docs/cloud-agent/self-hosted-guides/kubernetes)).
The controller container additionally needs `kubectl`.

### Existing Secret

```bash
kubectl create secret generic cursor-workers-api-key \
  --from-literal=api-key='YOUR_SERVICE_ACCOUNT_API_KEY' \
  -n cursord

helm upgrade --install my-workers ./chart \
  --namespace cursord --create-namespace \
  --set image.repository=YOUR_REGISTRY/YOUR_WORKER_IMAGE \
  --set image.tag=YOUR_TAG \
  --set pool=default \
  --set controller.warmIdle=3 \
  --set auth.existingSecret=cursor-workers-api-key
```

### Chart-managed Secret

```bash
helm upgrade --install my-workers ./chart \
  --namespace cursord --create-namespace \
  --set image.repository=YOUR_REGISTRY/YOUR_WORKER_IMAGE \
  --set image.tag=YOUR_TAG \
  --set controller.warmIdle=3 \
  --set auth.apiKey='YOUR_SERVICE_ACCOUNT_API_KEY'
```

Prefer `--set` or a gitignored values overlay over committing `auth.apiKey`.

Render without installing:

```bash
helm template my-workers ./chart \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=sample \
  --set auth.existingSecret=cursor-workers-api-key
```

## How workers are created

The controller Deployment is **one replica of the controller process**.

On each `--spawn` (claim-then-spawn, or once per missing warm worker) the hook
runs `kubectl create -f -` with a Pod spec:

1. `restartPolicy: Never` — when `--idle-release-timeout` exits 0, the Pod is
   **Succeeded**.
2. The worker registers with `CURSOR_AGENT_WORKER_ID` from the hook env (the
   id the controller claimed or generated).
3. `CURSOR_API_KEY` is mounted from the same Secret; the worker Pod uses that
   key rather than the controller ServiceAccount token.
4. `agent worker start` mints a session at the CLI auth default
   (`https://api2.cursor.sh`). The controller default (`https://api.cursor.com`)
   is for `/v0/private-workers`. Set `controller.endpoint` to override the
   controller process.

### Claim-then-spawn (`controller.warmIdle=0`, default)

The controller lists/watches pending pool requests, claims each one, and execs
`--spawn` once per claim. Worker Pods appear when there is demand.

### `--warm-idle` (`controller.warmIdle > 0`)

Passed through as `agent worker controller --warm-idle <count>`. The controller
keeps `<count>` idle workers connected in `pool` by running the spawn hook once
per missing warm worker. Replacements are new Pods.

When a session finishes and the worker exits, that Pod completes. The next
warm reconcile sees idle below target and spawns again.

Run one warm controller per pool. Two concurrent warm controllers can
transiently over-spawn. This chart uses `strategy: Recreate` on the controller
Deployment so a rollout keeps a single controller.

Succeeded/Failed worker Pods stay until you delete them:

```bash
kubectl -n cursord delete pod -l app.kubernetes.io/component=worker \
  --field-selector=status.phase=Succeeded
```

## Compared to the operator

| Operator (`WorkerDeployment`) | This chart |
|-------------------------------|----------|
| `readyReplicas` = idle workers; claimed `/readyz` 503 triggers replacements | `--warm-idle` (optional) or claim-then-spawn; each worker is a Pod created by `--spawn` |
| Busy-safe rolling updates (drain idle, wait for busy) | Controller uses Recreate; worker Pods are one-shot |
| Operator token exchange + `--auth-token-file` rotation | Long-lived `CURSOR_API_KEY` from a Secret |
| `WorkerDeployment` CRD + `worker-set-controller` | Vanilla Pods via `--spawn` |
| Optional demand autoscaling / scale-to-zero | Claim-then-spawn if `warmIdle=0`; otherwise a fixed idle target via `--warm-idle` |

Use the operator chart when you need those operator behaviors.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `pool` | `default` | `--pool` name (controller and spawned workers) |
| `idleReleaseTimeout` | `600` | `--idle-release-timeout` seconds on worker Pods |
| `workerDir` | `/workspace` | `--worker-dir`; empty omits the flag |
| `managementAddr` | `0.0.0.0:8080` | `--management-addr` for `/readyz` and `/healthz` |
| `image.repository` | `""` (required) | Worker image (`agent` + git + repo). Used for the controller too unless overridden |
| `image.tag` | `""` (required unless `digest`) | Image tag |
| `image.digest` | `""` | Optional `sha256:…`; takes precedence over tag |
| `labels` | `[]` | Extra `--label key=value` flags on workers |
| `extraArgs` | `[]` | Extra worker CLI args before `start` |
| `auth.existingSecret` | `""` | Existing Secret name |
| `auth.secretKey` | `api-key` | Key inside the Secret |
| `auth.apiKey` | `""` | Create a Secret from this value when `existingSecret` is empty |
| `controller.enabled` | `true` | Deploy the in-cluster controller |
| `controller.warmIdle` | `0` | `0` omits `--warm-idle` (claim mode). A positive integer is passed through as `--warm-idle` |
| `controller.repository` | `""` | Optional `--repository` on the controller |
| `controller.endpoint` | `""` | Optional controller `CURSOR_API_ENDPOINT` override |
| `controller.image.*` | empty | Optional controller image (`agent` + `kubectl`) |
| `rbac.create` | `true` | Role/RoleBinding for Pod create |
| `resources` | 250m / 512Mi request, 2Gi memory limit | Spawned **worker** Pod resources |
| `probes.readiness.path` | `/readyz` | Readiness HTTP path on worker Pods |
| `probes.liveness.path` | `/healthz` | Liveness HTTP path on worker Pods |

## Health checks

Same contract as the public Kubernetes guide (on **worker** Pods):

| Endpoint | 200 | 503 |
|----------|-----|-----|
| `/healthz` | Process is running | — |
| `/readyz` | Connected and idle | Starting, or running a session |

Only worker Pods serve these endpoints.

## Validate locally

```bash
./scripts/helm-validate.sh
```
