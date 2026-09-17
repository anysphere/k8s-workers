# Run Cursor cloud agents on Kubernetes

This template runs Cursor Self-Hosted Machines (self-hosted pool) workers in
your cluster. Cursor hosts the agent loop. An in-cluster
`agent worker controller` kubectl-creates one worker Pod per spawn; each
worker runs tool calls inside your cluster network.

For the published `worker-set-controller` / `WorkerDeployment` path, see
[Deploying with Kubernetes](https://cursor.com/docs/cloud-agent/self-hosted-guides/kubernetes).
Use this sample for controller `--spawn` Pods (claim-then-spawn or
`--warm-idle`).

## How it works

1. You start a cloud agent at [cursor.com/agents](https://cursor.com/agents)
   against a self-hosted pool. The request stays pending until a worker claims
   it (or a warm idle worker is already connected).
2. Helm installs a single-replica Deployment of
   `agent worker controller --spawn /hooks/spawn-pod.sh --pool <name>`.
3. On each `--spawn`, the hook runs `kubectl create -f -` for a Pod with
   `restartPolicy: Never`. That Pod starts
   `agent worker --pool <name> --worker-dir <dir> start`.
4. The worker opens an outbound bridge to Cursor and executes tool calls in
   your cluster. When `--idle-release-timeout` elapses after the session, the
   worker exits 0 and the Pod becomes **Succeeded**.

## Key properties

| Property | Description |
| --- | --- |
| Controller + spawn | One controller process; workers are kubectl-created Pods |
| One-shot Pods | `restartPolicy: Never` — idle exit completes the Pod; next spawn creates a new one |
| Claim or warm | `controller.warmIdle=0` claim-then-spawn, or `>0` for `--warm-idle N` |
| Service account key | Long-lived `CURSOR_API_KEY` from a Secret |
| Additive | Safe to run alongside `worker-set-controller` / `WorkerDeployment` |
| Hibernation | **Off by default.** Opt in with `hibernation.enabled=true` plus a pool reconnect window to keep a per-worker workspace volume across idle exits. See [Hibernation](#hibernation-opt-in) |

## Pool and repo modes

Product semantics:
[Self-hosted pools](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool)
([Any repo](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool#any-repo-pools),
[pool names](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool#pool-names),
[multiple repo roots](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool#register-multiple-repo-roots)).
`repo` and `pool` labels are reserved; the worker derives `repo=` from a git
remote when one exists.

**This template’s chart default is `pool: default`.** That is the unnamed pool
the CLI joins when `--pool` has no name. A repo-backed `default` pool shows
under that repository. An any-repo fleet uses a name of its own (`k8s-workers`
in the examples below) so it appears under **Any repo**. Register that name
with `POST /v0/private-workers/pools` (omit repo fields) so the picker lists it
before a worker connects. Keep Helm `pool` and the dashboard pool name the same.

Build the worker image so `workerDir` is either a clone with a remote
(repo-bound) or a directory with no git remote (any-repo).

### Any-repo mode

Dashboard: **Any repo**. Docs:
[Any repo pools](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool#any-repo-pools).
Routing is by **pool name**. Give the fleet a name other than `default`, then
register it:

```bash
curl --request POST \
  --url "https://api.cursor.com/v0/private-workers/pools" \
  -u "$CURSOR_API_KEY:" \
  --header 'Content-Type: application/json' \
  --data '{"scope":"team","poolName":"k8s-workers"}'
```

Users specify that name when starting an agent: the dashboard **Any repo**
group, `pool=k8s-workers` on Slack/GitHub/Linear, or the API with
`env.type: "pool"` and `env.name`, omitting `repos`. Those starts leave off
`repo=` labels.

Controller (what Helm runs):

```bash
agent worker controller --spawn /hooks/spawn-pod.sh --pool <name>
```

One chart install per pool is the usual pattern. Repeat `--pool` only when a
single controller should serve several pools.

Worker Pod (spawned by the hook):

```bash
agent worker --pool <name> --worker-dir /workspace start
```

`/workspace` should have no git remote so the worker leaves off `repo=`
labels. `--pool` on the guest must match the controller pool name.

Optional: if a pending request carries a clone URL and your image/entrypoint
clones it into `--worker-dir`, that session becomes repo-bound. To stay
any-repo, keep `--worker-dir` as a directory without a git remote and let the
agent or your scripts clone into it.

### Repo-bound mode

Routing is by **git remote**. Bake (or init-container clone) a repository
into `workerDir` with a configured remote. The worker derives `repo=owner/name`
from that remote (leave `repo=` labels unset; the worker sets them).

Users pick that repository in the dashboard (the pool appears under that
repo). Replace any public sample remote with your real repository before you
run real work. Private remotes need git auth (HTTPS token or SSH) in the
worker image or via `extraEnv` / mounted credentials.

Optional controller filter: set `controller.repository` so the controller
only handles pending requests for that repository identity.

### Many repositories

One named any-repo pool covers a large GitHub Enterprise fleet. Routing is
the pool name, not a baked remote, so thousands of repos share the same image
and controller.

- Register the pool up front (the curl above) so it stays in the picker with
  zero connected workers.
- Leave `workerDir` as an empty directory. A git remote in that directory
  makes the worker repo-bound to that one remote.
- Put `git`, your GHE credentials, and the build tools a session needs in the
  image. Clone the claimed repo in the session, or from a `sessionStart` hook
  in `workerDir`, with those credentials. A shallow clone of the one repo the
  agent is starting is the working set; the image stays the same for every
  repo.
- `--clone-git-repos` clones with a minted GitHub token. That path needs the
  GitHub App to reach the host, and it applies to a named pool other than
  `default`. A private GHE server is cloned by the image with its own
  credentials.
- Claim-mode spawn env includes `CURSOR_REPO_URL` when the request targets a
  repository. An Any repo start omits `repos`, so that variable is unset and
  the session does the clone.
- `controller.warmIdle` covers process startup. Time to first edit is then
  the clone. Raise `idleReleaseTimeout` so a follow-up reuses that checkout.
  Start with a small idle count; one warm controller per pool.

## Controller modes (claim vs warm idle)

Independent of any-repo vs repo-bound.

### Claim-then-spawn (`controller.warmIdle=0`, default)

The controller watches pending pool requests, claims each one, and runs
`--spawn` once per claim. Worker Pods appear when there is demand. Closest to
the Cloudflare / Lambda “spawn on claim” templates.

### Warm idle (`controller.warmIdle > 0`)

Passed through as `agent worker controller --warm-idle <count>`. The
controller keeps `<count>` idle workers connected in `pool` by running the
spawn hook once per missing warm worker (new Pods each time, rather than
patching a Deployment or HPA).

When a session finishes and the worker exits, that Pod completes. The next
warm reconcile sees idle below target and spawns again.

Run **one** warm controller per pool. Two concurrent warm controllers can
transiently over-spawn. This chart uses `strategy: Recreate` on the
controller Deployment so a rollout keeps a single controller.

## Prerequisites

- A Kubernetes cluster (v1.24+) and `kubectl` context
- [Helm](https://helm.sh/) v3
- A Cursor Enterprise team with Self-Hosted Machines / self-hosted pools
  enabled
- A [service account API key](https://cursor.com/docs/account/enterprise/service-accounts)
  for pool workers (personal API keys are rejected)
- A worker container image that includes:
  - the `agent` / `cursor-agent` CLI. Warm reconcile parses
    `GET /v0/private-workers/pools`, including `workerReadyTimeoutSeconds`.
    `2026.09.03-a76a283` accepts that field. If the image does not bake the
    binary, download the [cursor.com/install](https://cursor.com/install)
    build in the container `command` before exec. The chart uses the same
    `command` for the controller and for spawned workers.
  - `git` on `PATH` (required for git remotes / `--clone-git-repos`)
  - a workspace directory at `workerDir` (default `/workspace`)
  - `/bin/sh` if you turn on [hibernation](#hibernation-opt-in) (the
    entrypoint wrapper runs before the CLI)
- The controller container also needs `kubectl` on `PATH` and a POSIX shell
  (`sh`, `sed`, `tr`, `cut`, `date`; any Debian, Ubuntu, Alpine or busybox
  base has them). Override `controller.image` if your worker image has
  `agent` but not `kubectl`. A base image that has neither can install both
  in that same `command`.

## Install

1. Clone this repository.

   ```bash
   git clone https://github.com/anysphere/k8s-workers.git
   cd k8s-workers
   ```

2. Create a namespace and store the service account API key.

   ```bash
   kubectl create namespace cursord

   kubectl create secret generic cursor-workers-api-key \
     --from-literal=api-key='YOUR_SERVICE_ACCOUNT_API_KEY' \
     -n cursord
   ```

3. Install the chart (claim-then-spawn, named any-repo pool).

   ```bash
   helm upgrade --install my-workers ./chart \
     --namespace cursord --create-namespace \
     --set image.repository=YOUR_REGISTRY/YOUR_WORKER_IMAGE \
     --set image.tag=YOUR_TAG \
     --set pool=k8s-workers \
     --set controller.warmIdle=0 \
     --set auth.existingSecret=cursor-workers-api-key
   ```

   For a warm pool of three idle workers instead:

   ```bash
   helm upgrade --install my-workers ./chart \
     --namespace cursord \
     --set image.repository=YOUR_REGISTRY/YOUR_WORKER_IMAGE \
     --set image.tag=YOUR_TAG \
     --set pool=k8s-workers \
     --set controller.warmIdle=3 \
     --set auth.existingSecret=cursor-workers-api-key
   ```

   Chart-managed Secret (prefer `--set` or a gitignored values overlay over
   committing the key):

   ```bash
   helm upgrade --install my-workers ./chart \
     --namespace cursord --create-namespace \
     --set image.repository=YOUR_REGISTRY/YOUR_WORKER_IMAGE \
     --set image.tag=YOUR_TAG \
     --set pool=k8s-workers \
     --set auth.apiKey='YOUR_SERVICE_ACCOUNT_API_KEY'
   ```

4. Confirm the controller is up.

   ```bash
   kubectl -n cursord get deploy,pods -l app.kubernetes.io/instance=my-workers
   kubectl -n cursord logs -l app.kubernetes.io/component=controller -f
   ```

5. Start an agent from [cursor.com/agents](https://cursor.com/agents)
   (see [Run a cloud agent](#run-a-cloud-agent) below).

Render without installing:

```bash
helm template my-workers ./chart \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=test \
  --set auth.existingSecret=cursor-workers-api-key
```

Local lint / kubeconform (optional):

```bash
./scripts/helm-validate.sh
```

Full values reference: [chart/README.md](chart/README.md).

## Run a cloud agent

### Any-repo mode

1. Open [cursor.com/agents](https://cursor.com/agents).
2. Start an agent, pick the **Any repo** group, and choose the pool name
   (`k8s-workers` unless you overrode `pool`).
3. From Slack/GitHub/Linear use `pool=<name>`. From the API use
   `env.type: "pool"` and `env.name`, and omit `repos`.
4. With `controller.warmIdle=0`, the controller claims and spawns a Pod.
   With `warmIdle>0`, an idle worker should already be connected.

### Repo-bound mode

1. Open [cursor.com/agents](https://cursor.com/agents).
2. Start an agent, pick the repository that matches the git remote baked
   into your worker image, and choose **Self-hosted** with the same pool
   name.
3. The worker advertises `repo=` from that remote. Private remotes need
   credentials in the image or via chart `extraEnv` / volumes.

For a first walkthrough without private git auth, bake
`https://github.com/octocat/Hello-World` into the image workspace, then
replace it with your real repository before production work.

## Hibernation (opt-in)

By default a worker Pod is one-shot: it exits after `idleReleaseTimeout`,
and a follow-up that arrives later lands on a fresh Pod with a fresh
workspace. Hibernation keeps the workspace. Each worker id gets a
PersistentVolumeClaim `ws-<worker-id>` mounted at `workerDir`; the Pod still
exits when idle, but the volume stays, and when a follow-up arrives Cursor
asks the controller to bring the *same* worker id back. The spawn hook mounts
the same claim into a new Pod and the agent resumes on its files.

Nothing about this is on unless you turn it on. **Two independent gates must
both be set**, and both default to off:

| Gate | Where | Default | What it controls |
| --- | --- | --- | --- |
| `hibernation.enabled` | this chart | `false` | Whether the hook creates and mounts `ws-<worker-id>` claims, renders the reaper CronJob, and grants the controller PVC rights |
| `workerReadyTimeoutSeconds` | the pool in Cursor | `0` | How long Cursor waits for the claimed worker to come back before handing the follow-up to any worker |

| Pool window | `hibernation.enabled` | What you get |
| --- | --- | --- |
| `0` | `false` | Today's behavior. |
| `0` | `true` | Claims are created and never reused; the reaper deletes them after `hibernation.pvcTtl`. `helm install` NOTES remind you to set the window. |
| `> 0` | `false` | Cursor asks for a wake; the hook spawns a fresh Pod with the claimed id and no volume. Same as expiry, only sooner. |
| `> 0` | `true` | Hibernation. |

`k8s-workers` is one release per pool, so a `dev-loop` pool can hibernate
while a `ci` pool in the same cluster stays one-shot.

### What persists, and what does not

Disk only. Files under `workerDir` (and under `hibernation.homeDir` if you
set `hibernation.mountHome=true`) survive. Processes, dev servers, tmux
sessions, and anything installed outside those paths are gone on wake.
Cursor-managed hibernation snapshots memory; this does not.

### Turn it on

1. Build the worker image so it can populate an empty workspace. The claim is
   mounted **over** `workerDir`, so anything the image baked there is hidden.
   Pick one:
   - Bake the clone somewhere else (say `/opt/workspace-seed`) and set
     `hibernation.seed.fromPath=/opt/workspace-seed`; the entrypoint copies it
     into the empty volume on first use.
   - Set `hibernation.seed.cloneUrl` and provide git credentials through
     `extraEnv` or mounted volumes; the entrypoint clones on first use.
   - Any-repo pools: leave both empty. The agent clones into the empty
     workspace as it does today.

2. Install or upgrade with the feature on. `hibernation.storageClassName`
   should be a class with `volumeBindingMode: WaitForFirstConsumer` and
   encryption at rest. Empty uses the cluster's default StorageClass, and
   only when one is marked default. A cluster that has classes but no default
   leaves the claim `Pending` with `no storage class is set`.

   ```bash
   helm upgrade --install my-workers ./chart \
     --namespace cursord --create-namespace \
     --set image.repository=YOUR_REGISTRY/YOUR_WORKER_IMAGE \
     --set image.tag=YOUR_TAG \
     --set pool=default \
     --set auth.existingSecret=cursor-workers-api-key \
     --set idleReleaseTimeout=300 \
     --set hibernation.enabled=true \
     --set hibernation.size=20Gi \
     --set hibernation.storageClassName=YOUR_STORAGE_CLASS \
     --set hibernation.seed.fromPath=/opt/workspace-seed
   ```

3. Give the pool a reconnect window in Cursor. The chart cannot do this for
   you yet; `helm install` prints the exact call in its NOTES. Use the pool's
   **team-scoped** service account key (a repo-scoped key cannot register the
   window):

   ```bash
   curl --request POST \
     --url "https://api.cursor.com/v0/private-workers/pools" \
     -u "$CURSOR_API_KEY:" \
     --header 'Content-Type: application/json' \
     --data '{"scope":"team","poolName":"default","workerReadyTimeoutSeconds":900}'
   ```

   For a repo-backed pool include `repoOwner`, `repoName`, and `repoUrl` in
   the body. Omitting `workerReadyTimeoutSeconds` on a later call never
   resets an existing window. Set it to `0` to turn wakes off again.

4. Check it. Start an agent against the pool, have it create an uncommitted
   file, and wait for the Pod to go `Succeeded`:

   ```bash
   kubectl -n cursord get pods,pvc -l app.kubernetes.io/component=worker
   kubectl -n cursord get pvc -l app.kubernetes.io/component=workspace
   ```

   The claim is `Bound` with no running consumer. Send a follow-up asking
   for `git status`: a new Pod named `<worker-id>-<suffix>` appears with the
   same `CURSOR_AGENT_WORKER_ID`, its log starts with
   `entrypoint: workspace /workspace already populated; resuming`, and the
   agent still sees the file.

### Turn it off

`helm upgrade ... --set hibernation.enabled=false` returns to one-shot Pods
on the next spawn. Existing `ws-*` claims are not deleted by the chart; the
reaper is gone with the feature, so delete them yourself:

```bash
kubectl -n cursord delete pvc -l app.kubernetes.io/component=workspace
```

Set the pool window back to `0` with the same API call, or leave it: with the
feature off, a wake is just a fresh Pod.

### Sizing the two clocks

A wake has to beat two timers. `workerReadyTimeoutSeconds` runs from the
follow-up's arrival in Cursor; the worker's own `--idle-release-timeout`
(`idleReleaseTimeout`) also runs from that arrival, and a worker that
connects after it elapsed is released at once. Both must exceed the
worst-case wake: schedule, image pull, volume attach, connect, plus node
scale-up when the cluster is at zero. A short idle timeout with a slow wake
produces a release loop. `hibernation.wakeWindowSeconds` (default `900`) is
only what NOTES print for the API call; the chart does not set it on the
pool.

### Reaper

Cursor never deletes Kubernetes objects. A CronJob
(`<release>-k8s-workers-reaper`, every 15 minutes by default) deletes:

- workspace claims whose `cursor.com/last-used-epoch` is older than
  `hibernation.pvcTtl` (default `7d`) and that no running Pod uses;
- `Succeeded` / `Failed` worker Pods older than `hibernation.podTtl`
  (default `1h`).

A finished Pod holds a `kubernetes.io/pvc-protection` finalizer on its claim,
so the reaper deletes a worker's finished Pods before its claim. Run it by
hand with `kubectl -n cursord create job --from=cronjob/<release>-k8s-workers-reaper reap-now`.
Disable it with `hibernation.reaper.enabled=false` and delete claims yourself.

The reaper container runs `/hooks/reaper.sh`. It does not use `command`, so a
start script that installs `kubectl` for the controller does not put it on
the reaper's `PATH`. `hibernation.reaper.image` defaults to the controller
image; that image must already contain `kubectl`, or set
`hibernation.reaper.image` to one that does.

### Caveats

- **Zone pinning.** A `ReadWriteOnce` block volume is bound to the zone (or
  node, for local storage) where it was provisioned. A wake Pod that cannot
  schedule there stays `Pending` with `volume node affinity conflict` until
  the window lapses, and the workspace is lost anyway. Use per-zone node
  groups so the autoscaler can grow the right zone, a regional disk, or
  `ReadWriteMany` network storage (slower `git` and `node_modules` I/O).
- **Attach race.** The previous Pod may still be `Terminating` when the wake
  Pod starts; Kubernetes clears the transient Multi-Attach error itself.
  Budget a few seconds.
- **Security.** The claim holds a checkout and possibly credential residue
  from `--mint-github-token` or `--sync-dashboard-secrets`. Use an encrypted
  storage class. Claims are keyed strictly by worker id, so a volume never
  mounts for a different agent. `hibernation.mountHome` is off by default for
  this reason.
- **Volume ownership.** A newly provisioned volume is `root:root` and mode
  `755`. The agent runs as the image user. If that user is not root, set
  `podSecurityContext.fsGroup` to its gid so the kubelet makes the mount
  group-writable before the container starts. The container user cannot
  `chown` the mount from `command`. Do not set a default `fsGroup`; images
  that run as root do not need one.
- **Quotas.** Every worker id that ever ran leaves a claim until the TTL. A
  team can run up to 1000 workers; size the storage quota, and note that EBS
  caps attachments per node near 25.
- **Session hooks.** `sessionStart` fires on claim. Whether it fires again
  when a wake adopts the claim is not confirmed; do not rely on it to rebuild
  state on wake yet.

## Alternative: run the controller on your laptop

Useful while iterating on the spawn hook or image.

1. Install the CLI from [cursor.com/install](https://cursor.com/install).
2. Ensure `kubectl` points at the cluster and can create Pods in the
   target namespace.
3. Export `CURSOR_API_KEY` and run:

   ```bash
   export CURSOR_API_KEY='YOUR_SERVICE_ACCOUNT_API_KEY'

   agent worker controller --spawn ./path/to/spawn-pod.sh --pool k8s-workers
   # warm idle:
   # agent worker controller --spawn ./path/to/spawn-pod.sh --pool k8s-workers --warm-idle 2
   ```

Point `--spawn` at a copy of the chart's spawn ConfigMap. The hook reads its
Pod (and, with hibernation, PVC and entrypoint) manifests from the directory
it lives in, so dump every key of the ConfigMap into one directory:

```bash
mkdir -p hooks
kubectl -n cursord get cm my-workers-k8s-workers-spawn -o json > spawn-cm.json
for key in $(jq -r '.data | keys[]' spawn-cm.json); do
  jq -r --arg k "$key" '.data[$k]' spawn-cm.json > "hooks/$key"
done
chmod +x hooks/spawn-pod.sh
agent worker controller --spawn ./hooks/spawn-pod.sh --pool default
```

The in-cluster install remains the supported long-running path.

## Monitoring

```bash
# Controller
kubectl -n cursord logs -l app.kubernetes.io/component=controller -f

# Worker Pods created by --spawn
kubectl -n cursord get pods -l app.kubernetes.io/component=worker

# Succeeded/Failed one-shot Pods stay until you delete them (the hibernation
# reaper does this for you when that feature is on)
kubectl -n cursord delete pod -l app.kubernetes.io/component=worker \
  --field-selector=status.phase=Succeeded

# Hibernation only: workspace claims and their last use
kubectl -n cursord get pvc -l app.kubernetes.io/component=workspace \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,LAST_USED:.metadata.annotations.cursor\.com/last-used-at'
kubectl -n cursord get cronjob,jobs -l app.kubernetes.io/component=reaper
```

Worker Pods are named `<worker-id>-<suffix>` and carry the worker id in the
`cursor.com/worker-id` label, so all episodes of one worker are
`kubectl -n cursord get pods -l cursor.com/worker-id=<worker-id>`.

Worker health (same contract as the public Kubernetes guide):

| Endpoint | 200 | 503 |
| --- | --- | --- |
| `/healthz` | Process is running | — |
| `/readyz` | Connected and idle | Starting, or running a session |

Only worker Pods serve these endpoints.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Nothing is ever claimed | Controller logs; `CURSOR_API_KEY` Secret; `pool` matches the dashboard; Self-Hosted enabled for the team |
| `HTTP 401` / invalid API key | Use a **service account** key with agent scope, not a personal key |
| Pods spawn then exit immediately | Image has `agent` + `git`; `workerDir` exists; check worker logs |
| Agent cannot find the pool under a repo | You started any-repo (no `repo=` labels). Pick **Any repo**, or bake a git remote for repo-bound |
| Pool missing from the web UI | Register a named pool (`POST /v0/private-workers/pools`, no repo fields) and set Helm `pool` to that name. `default` is the unnamed pool; a repo-backed `default` pool shows under its repository |
| `unrecognized_keys` / `workerReadyTimeoutSeconds` | Controller CLI is older than the pools response. Use a build that accepts that field (`2026.09.03-a76a283` does) |
| Warm idle overshoots | Only one controller per pool; chart uses Recreate — avoid a second Helm release on the same pool with `warmIdle>0` |
| Controller CrashLoop, `exec: "agent": executable file not found` | The image does not contain the CLI. Download the [cursor.com/install](https://cursor.com/install) build in `command` before exec. The same `command` runs in worker Pods. |
| Controller CrashLoop | Controller image missing `kubectl` or `agent`; RBAC Role cannot create Pods; Secret key name ≠ `auth.secretKey` |
| Follow-up lands on a fresh workspace with hibernation on | Pool window still `0` (run the NOTES API call with a team-scoped key); `idleReleaseTimeout` or the window shorter than the wake; claim reaped (`pvcTtl`) or deleted; hook logged `exit 3` because `ws-<worker-id>` was gone |
| `Permission denied` writing under `workerDir` | The new volume is `root:root` `755`. Set `podSecurityContext.fsGroup` to the image user's gid (often `1000`). See [Caveats](#caveats). |
| `ws-*` stays `Pending`, storage class blank, `no storage class is set` | The cluster has no default StorageClass. Set `hibernation.storageClassName`. |
| `ws-*` stays `Pending`, `Waiting for a volume to be created` by `ebs.csi.aws.com` | The class (often in-tree `gp2`, provisioner `kubernetes.io/aws-ebs`) is translated to the EBS CSI driver, and that driver is not installed. Install the `aws-ebs-csi-driver` add-on, or name a class whose provisioner is running. |
| Wake Pod stays `Pending`, `volume node affinity conflict` | The claim's zone/node has no capacity. Per-zone node groups, regional disk, or `ReadWriteMany` storage. See [Caveats](#caveats) |
| Reaper Job `Error`, `kubectl: not found` | The reaper does not run `command`. `hibernation.reaper.image` (the controller image when empty) must have `kubectl` on `PATH`, or set `hibernation.reaper.enabled=false`. |
| `ws-*` claim stuck `Terminating` | A `Succeeded`/`Failed` Pod still references it (`kubernetes.io/pvc-protection`). Delete those Pods; the reaper does this before deleting a claim |
| Worker Pod fails at start with hibernation on | Worker image lacks `/bin/sh`; `seed.fromPath` missing in the image; `seed.cloneUrl` needs `git` and credentials |

## Compared to the operator

| Operator (`WorkerDeployment`) | This chart |
| --- | --- |
| `readyReplicas` = idle workers; busy-safe rolling updates | `--warm-idle` or claim-then-spawn; one-shot Pods |
| Operator token exchange + `--auth-token-file` | Long-lived `CURSOR_API_KEY` Secret |
| `WorkerDeployment` + `worker-set-controller` | Vanilla Pods via `--spawn` |
| Optional demand autoscaling / scale-to-zero | Claim-then-spawn (`warmIdle=0`) or fixed idle via `--warm-idle` |

## Related resources

- [Self-Hosted Pool](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool)
  ([Any repo](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool#any-repo-pools),
  [pool names](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool#pool-names),
  [multiple repo roots](https://cursor.com/docs/cloud-agent/self-hosted-guides/pool#register-multiple-repo-roots))
- [Deploying with Kubernetes](https://cursor.com/docs/cloud-agent/self-hosted-guides/kubernetes) (operator path)
- [Service accounts](https://cursor.com/docs/account/enterprise/service-accounts)
- This repo: [`chart/`](chart/), [`scripts/helm-validate.sh`](scripts/helm-validate.sh)

## License

First-party code in this repository is licensed under the **Apache License, Version 2.0** — see [`LICENSE`](LICENSE).

## Trademarks

This license does not grant permission to use the trade names, trademarks, service marks, or product names of SpaceXAI, Anysphere, Cursor, or Grok, except as required for reasonable and customary use in describing the origin of the Work.

Kubernetes is a registered trademark of The Linux Foundation. All other trademarks are the property of their respective owners.

## Disclaimer

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
