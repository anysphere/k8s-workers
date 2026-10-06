# k8s-workers Helm Chart

Step-by-step install, any-repo vs repo-bound, and claim vs warm-idle modes:
see the root [README.md](../README.md).

Deploys an in-cluster `agent worker controller` that kubectl-creates Cursor
self-hosted **pool** workers as vanilla Kubernetes **Pods**.

This chart replaces the deprecated `worker-set-controller` operator. It installs
no CRD and no `WorkerDeployment`, so it can share a cluster with an existing
operator install. See
[Differences from the deprecated operator](#differences-from-the-deprecated-operator).

## What this installs

| Resource | When | Description |
|----------|------|-------------|
| Deployment (1 replica) | `controller.enabled` | `agent worker controller --spawn …` (the controller process) |
| ConfigMap | `controller.enabled` | Spawn hook plus the worker Pod manifest it `kubectl create`s (and, with hibernation, the PVC manifest and entrypoint) |
| Role / RoleBinding | `controller.enabled` and `rbac.create` | Namespace permission to create/get/list Pods (plus create/get/list/patch PVCs with hibernation, and create Secrets plus delete Pods with `auth.sessionToken`) |
| ServiceAccount | `serviceAccount.create` | Controller SA; token automount on (required for kubectl) |
| Secret | `auth.apiKey` set and `auth.existingSecret` empty | Holds `CURSOR_API_KEY` |
| CronJob + ConfigMap + ServiceAccount + Role + RoleBinding (`*-reaper`) | `hibernation.enabled` and `hibernation.reaper.enabled` | Deletes stale workspace PVCs and finished worker Pods |

Worker **instances** are outside the Helm release. Each `--spawn` creates a Pod
named `<worker-id>-<suffix>` with `restartPolicy: Never`. By default workers
authenticate with the team **service account API key** (`CURSOR_API_KEY`).
With [session tokens](#session-tokens-opt-in) on, only the controller holds
that key, and each worker Pod reads a token for its own claim from a Secret
`tok-<worker-id>-<suffix>` that the Pod owns. With
[hibernation](#hibernation-opt-in) on, each worker id also owns a
PersistentVolumeClaim `ws-<worker-id>` that the hook creates on first use.

The controller image must include the `agent` CLI **and** `kubectl` on `PATH`,
plus a POSIX shell (`sh`, `sed`, `tr`, `cut`, `date`). The CLI from
[cursor.com/install](https://cursor.com/install) accepts
`workerReadyTimeoutSeconds` on the pools response. Override
`controller.image` when the worker image has `agent` but not `kubectl`. A
base image that has neither can install both in `command` before exec; that
value is shared with spawned workers.

## Quick start

Your worker image must include the `agent` CLI, `git` on `PATH`, and a
workspace at `workerDir` (see [Prerequisites](../README.md#prerequisites)).
The controller container additionally needs `kubectl`.

The chart is published to Amazon ECR Public at
`oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers`, and installing it needs no
registry login. Replace `0.2.2` below with the version you want from the
[releases page](https://github.com/anysphere/k8s-workers/releases).

### Existing Secret

```bash
kubectl create secret generic cursor-workers-api-key \
  --from-literal=api-key='YOUR_SERVICE_ACCOUNT_API_KEY' \
  -n cursord

helm upgrade --install my-workers oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers \
  --version 0.2.2 \
  --namespace cursord --create-namespace \
  --set image.repository=YOUR_REGISTRY/YOUR_WORKER_IMAGE \
  --set image.tag=YOUR_TAG \
  --set pool=k8s-workers \
  --set controller.warmIdle=3 \
  --set auth.existingSecret=cursor-workers-api-key
```

### Chart-managed Secret

```bash
helm upgrade --install my-workers oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers \
  --version 0.2.2 \
  --namespace cursord --create-namespace \
  --set image.repository=YOUR_REGISTRY/YOUR_WORKER_IMAGE \
  --set image.tag=YOUR_TAG \
  --set controller.warmIdle=3 \
  --set auth.apiKey='YOUR_SERVICE_ACCOUNT_API_KEY'
```

Prefer `--set` or a gitignored values overlay over committing `auth.apiKey`.

Render without installing:

```bash
helm template my-workers oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers \
  --version 0.2.2 \
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
   key rather than the controller ServiceAccount token. With
   `auth.sessionToken=true` the Pod gets no key; it reads a per-claim token
   from `/var/run/cursor/token` (see [Session tokens](#session-tokens-opt-in)).
4. `agent worker start` mints a session at the CLI auth default
   (`https://api2.cursor.sh`). The controller default (`https://api.cursor.com`)
   is for `/v0/private-workers`. Set `controller.endpoint` to override the
   controller process.

The hook substitutes exactly three tokens (`${WORKER_SLUG}`, `${WORKER_ID}`,
`${POOL}`) into the manifests with `sed`, after validating each to a safe
character set. With `auth.sessionToken` it also substitutes `${TOKEN_SECRET}`,
`${POD_NAME}`, `${POD_UID}`, and `${TOKEN_EXPIRES_AT}`; the token itself never
goes through `sed`. Any other `$` in your `command` or `extraArgs` is passed
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

Succeeded/Failed worker Pods (and, with session tokens, the token Secrets they
own) stay until you delete them (or until the hibernation reaper does):

```bash
kubectl -n cursord delete pod -l app.kubernetes.io/component=worker \
  --field-selector=status.phase=Succeeded
```

## Session tokens (opt-in)

Off by default (`auth.sessionToken=false`): every worker Pod gets the service
account key as `CURSOR_API_KEY`, in the environment where the agent runs
commands.

On, the key stays in the controller Pod:

1. The controller runs `agent worker controller --session-token`. A claim
   returns a token that serves only that claim, and a wake mints a fresh one
   for the same claim (`POST /v0/private-workers/tokens`). The spawn hook gets
   it as `CURSOR_AUTH_TOKEN` (plus `CURSOR_AUTH_TOKEN_EXPIRES_AT`) and never
   sees `CURSOR_API_KEY`.
2. The hook creates the worker Pod, then a Secret `tok-<worker-id>-<suffix>`
   holding the token, with an `ownerReference` to that Pod, so Kubernetes
   deletes the Secret with the Pod. If the Secret cannot be created, the hook
   deletes the Pod and exits 1.
3. The Pod mounts the Secret read-only at `/var/run/cursor` and runs
   `agent worker … --auth-token-file /var/run/cursor/token start`. The kubelet
   starts the container only once the Secret exists.

| | `auth.sessionToken=false` | `auth.sessionToken=true` |
| --- | --- | --- |
| Controller Pod | `CURSOR_API_KEY` | `CURSOR_API_KEY`, `--session-token` |
| Worker Pod | `CURSOR_API_KEY` in its environment | Token for its own claim in `/var/run/cursor/token`; no key |
| Controller Role | Pods: create, get, list | Adds Pods: delete; Secrets: create |
| `controller.warmIdle` | Any | Must be `0` |

Constraints:

- Claim mode only. Warm workers start before any claim, so there is no token
  to give them: the CLI rejects `--session-token` with `--warm-idle`, and the
  chart fails the render when `controller.warmIdle > 0`.
- The team needs private-worker session tokens enabled. Without them the
  controller exits with `--session-token needs private-worker session tokens
  enabled for this team`; it does not fall back to handing out the key.
- The controller image needs a CLI with `agent worker controller
  --session-token` (`2026.10.01-e373342` has it).
- Secrets are create-only for the controller: it cannot read, change, or
  delete any Secret, including the one holding the key. With
  `rbac.create=false`, grant `create` on `secrets` and `delete` on `pods`
  yourself.
- Nothing refreshes a running worker's token. The worker re-reads the file
  before reconnecting, and a wake gets a new Pod with a new token. The
  token's expiry is on its Secret as `cursor.com/token-expires-at`.
- A finished Pod keeps its Secret until the Pod is deleted. The hibernation
  reaper deletes finished Pods after `hibernation.podTtl`; otherwise delete
  them as shown above.
- The hook reads `/proc/sys/kernel/random/uuid` for the Secret name suffix.

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

A new volume is `root:root` mode `755`. If the image user is not root, set
`podSecurityContext.fsGroup` to that user's gid. The reaper Job does not run
`command`; `hibernation.reaper.image` must contain `kubectl` (it defaults to
the controller image).

Hibernation also needs a non-zero `workerReadyTimeoutSeconds` on the pool in
Cursor; `helm install` prints the `POST /v0/private-workers/pools` call in
its NOTES. Walkthrough, sizing, and caveats: root
[README → Hibernation](../README.md#hibernation-opt-in).

## Differences from the deprecated operator

| Operator (`WorkerDeployment`) | This chart |
|-------------------------------|----------|
| `readyReplicas` = idle workers; claimed `/readyz` 503 triggers replacements | `--warm-idle` (optional) or claim-then-spawn; each worker is a Pod created by `--spawn` |
| Busy-safe rolling updates (drain idle, wait for busy) | Controller uses Recreate; worker Pods are one-shot |
| Operator token exchange + `--auth-token-file` rotation | Default: long-lived `CURSOR_API_KEY` from a Secret, set in each worker Pod's environment. With `auth.sessionToken`: a per-claim token read with `--auth-token-file`, and only the controller holds the key |
| `WorkerDeployment` + `worker-set-controller` | Vanilla Pods via `--spawn` |
| Optional demand autoscaling / scale-to-zero | Claim-then-spawn if `warmIdle=0`; otherwise a fixed idle target via `--warm-idle` |
| Two controller replicas with leader election | One controller replica; nothing claims or spawns while it restarts |

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `pool` | `default` | `--pool` name. Use a name other than `default` for an any-repo fleet so it appears under Any repo |
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
| `auth.sessionToken` | `false` | Keep the key in the controller Pod; worker Pods read a per-claim token with `--auth-token-file`. Requires `controller.warmIdle=0`. See [Session tokens](#session-tokens-opt-in) |
| `controller.enabled` | `true` | Deploy the in-cluster controller |
| `controller.warmIdle` | `0` | `0` omits `--warm-idle` (claim mode). A positive integer is passed through as `--warm-idle` |
| `controller.repository` | `""` | Optional `--repository` on the controller |
| `controller.endpoint` | `""` | Optional controller `CURSOR_API_ENDPOINT` override |
| `controller.image.*` | empty | Optional controller image (`agent` + `kubectl`) |
| `rbac.create` | `true` | Role/RoleBinding for Pod create (plus PVCs with hibernation, Secret create and Pod delete with `auth.sessionToken`) |
| `resources` | 250m / 512Mi request, 2Gi memory limit | Spawned **worker** Pod resources |
| `podSecurityContext` | `{}` | Pod `securityContext`. Set `fsGroup` to the image user's gid when hibernation mounts a volume and that user is not root |
| `probes.readiness.path` | `/readyz` | Readiness HTTP path on worker Pods |
| `probes.liveness.path` | `/healthz` | Liveness HTTP path on worker Pods |
| `hibernation.enabled` | `false` | Opt in to per-worker workspace PVCs and wakes. Off renders nothing extra |
| `hibernation.wakeWindowSeconds` | `900` | `workerReadyTimeoutSeconds` to set on the pool (1..3600). Printed in NOTES; not applied by the chart |
| `hibernation.storageClassName` | `""` | PVC storage class. Empty uses the default StorageClass; if the cluster has none, the claim stays `Pending` |
| `hibernation.size` | `20Gi` | PVC size |
| `hibernation.accessModes` | `[ReadWriteOnce]` | PVC access modes |
| `hibernation.mountHome` | `false` | Also mount the claim's `home` subPath at `hibernation.homeDir` |
| `hibernation.homeDir` | `/root` | Mount point for the home subPath |
| `hibernation.seed.fromPath` | `""` | Copy this image path into an empty workspace volume on first use |
| `hibernation.seed.cloneUrl` | `""` | `git clone` this into an empty workspace volume on first use (needs `git` and credentials) |
| `hibernation.pvcTtl` | `7d` | Reaper deletes claims unused for this long (`<n>s`/`m`/`h`/`d`) |
| `hibernation.podTtl` | `1h` | Reaper deletes `Succeeded`/`Failed` worker Pods older than this |
| `hibernation.reaper.enabled` | `true` | Render the reaper CronJob (only with `hibernation.enabled`) |
| `hibernation.reaper.schedule` | `*/15 * * * *` | CronJob schedule |
| `hibernation.reaper.image.*` | empty | Reaper image (`kubectl` + `sh`). Empty uses the controller image. The Job does not run `command` |
| `hibernation.reaper.resources` | 50m / 64Mi request, 128Mi limit | Reaper Job resources |

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
