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
| ConfigMap | `controller.enabled` | Spawn hook plus the worker Pod manifest it `kubectl create`s (and, with hibernation, the PVC manifest and entrypoint) |
| Role / RoleBinding | `controller.enabled` and `rbac.create` | Namespace permission to create/get/list Pods (plus create/get/list/patch PVCs with hibernation) |
| ServiceAccount | `serviceAccount.create` | Controller SA; token automount on (required for kubectl) |
| Secret | `auth.apiKey` set and `auth.existingSecret` empty | Holds `CURSOR_API_KEY` |
| CronJob + ConfigMap + ServiceAccount + Role + RoleBinding (`*-reaper`) | `hibernation.enabled` and `hibernation.reaper.enabled` | Deletes stale workspace PVCs and finished worker Pods |

Worker **instances** are outside the Helm release. Each `--spawn` creates a Pod
named `<worker-id>-<suffix>` with `restartPolicy: Never`. Workers authenticate
with a team **service account API key** (`CURSOR_API_KEY`). With
[hibernation](#hibernation-opt-in) on, each worker id also owns a
PersistentVolumeClaim `ws-<worker-id>` that the hook creates on first use.

The controller image must include the `agent` CLI **and** `kubectl` on `PATH`,
plus a POSIX shell (`sh`, `sed`, `tr`, `cut`, `date`). Override
`controller.image` when the worker image has `agent` but not `kubectl`.

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
2. The Pod is created with `generateName: <worker-id>-`, so a later Pod for
   the same worker id (a hibernation wake) never collides with the finished
   one. The worker receives `CURSOR_AGENT_WORKER_ID` exactly as the controller
   claimed or generated it; `CURSOR_WORKER_NAME` is the Pod name.
3. `CURSOR_API_KEY` is mounted from the same Secret; the worker Pod uses that
   key rather than the controller ServiceAccount token.
4. `agent worker start` mints a session at the CLI auth default
   (`https://api2.cursor.sh`). The controller default (`https://api.cursor.com`)
   is for `/v0/private-workers`. Set `controller.endpoint` to override the
   controller process.

The hook substitutes exactly three tokens (`${WORKER_SLUG}`, `${WORKER_ID}`,
`${POOL}`) into the manifests with `sed`, after validating each to a safe
character set. Any other `$` in your `command` or `extraArgs` is passed
through untouched.

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

Succeeded/Failed worker Pods stay until you delete them (or until the
hibernation reaper does):

```bash
kubectl -n cursord delete pod -l app.kubernetes.io/component=worker \
  --field-selector=status.phase=Succeeded
```

## Hibernation (opt-in)

Off by default (`hibernation.enabled=false`), and off means the chart above
with no additions: no PersistentVolumeClaims, no CronJob, no PVC RBAC.

On, the spawn hook gives each worker id a PVC `ws-<worker-id>` mounted at
`workerDir`. The Pod still exits after `idleReleaseTimeout`, the claim stays,
and when a follow-up arrives inside the pool's reconnect window the
controller runs the hook again with `CURSOR_WAKE=1` and the same worker id.
The hook mounts the same claim into a new Pod and the agent resumes on its
files. Disk only: processes do not survive.

| `CURSOR_WAKE` | `hibernation.enabled` | Hook behavior |
| --- | --- | --- |
| unset | `false` | Fresh Pod, no volume. |
| unset | `true` | Create `ws-<worker-id>` if missing, stamp `cursor.com/last-used-*`, create the Pod with it mounted. |
| `1` | `false` | Fresh Pod with the claimed worker id and no volume. |
| `1` | `true` | Require `ws-<worker-id>`; mount it and stamp. If it is missing or terminating, exit 3 without spawning so the window lapses into a fresh claim. |

Warm spawns (`--warm-idle`) take the `unset` rows, so a warm worker owns its
claim before it is ever claimed.

Hibernation also needs a non-zero `workerReadyTimeoutSeconds` on the pool in
Cursor; `helm install` prints the `POST /v0/private-workers/pools` call in
its NOTES. Walkthrough, sizing, and caveats: root
[README → Hibernation](../README.md#hibernation-opt-in).

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
| `hibernation.enabled` | `false` | Opt in to per-worker workspace PVCs and wakes. Off renders nothing extra |
| `hibernation.wakeWindowSeconds` | `900` | `workerReadyTimeoutSeconds` to set on the pool (1..3600). Printed in NOTES; not applied by the chart |
| `hibernation.storageClassName` | `""` | PVC storage class; empty uses the cluster default. Prefer `WaitForFirstConsumer` and encryption |
| `hibernation.size` | `20Gi` | PVC size |
| `hibernation.accessModes` | `[ReadWriteOnce]` | PVC access modes |
| `hibernation.mountHome` | `false` | Also mount the claim's `home` subPath at `hibernation.homeDir` |
| `hibernation.homeDir` | `/root` | Mount point for the home subPath |
| `hibernation.seed.fromPath` | `""` | Copy this image path into an empty workspace volume on first use |
| `hibernation.seed.cloneUrl` | `""` | `git clone` this into an empty workspace volume on first use (needs `git` and credentials) |
| `hibernation.pvcTtl` | `72h` | Reaper deletes claims unused for this long (`<n>s`/`m`/`h`/`d`) |
| `hibernation.podTtl` | `1h` | Reaper deletes `Succeeded`/`Failed` worker Pods older than this |
| `hibernation.reaper.enabled` | `true` | Render the reaper CronJob (only with `hibernation.enabled`) |
| `hibernation.reaper.schedule` | `*/15 * * * *` | CronJob schedule |
| `hibernation.reaper.image.*` | empty | Reaper image (`kubectl` + `sh`); empty uses the controller image |
| `hibernation.reaper.resources` | 50m / 64Mi request, 128Mi limit | Reaper Job resources |

## Health checks

Same contract as the public Kubernetes guide (on **worker** Pods):

| Endpoint | 200 | 503 |
|----------|-----|-----|
| `/healthz` | Process is running | — |
| `/readyz` | Connected and idle | Starting, or running a session |

Only worker Pods serve these endpoints.

## Validate locally

Render, lint, and mock-spawn checks (no cluster needed):

```bash
./scripts/helm-validate.sh
```

End-to-end on a local kind cluster with a stub `agent` image (no Cursor
credentials; see the root README):

```bash
./scripts/kind-e2e.sh
```
