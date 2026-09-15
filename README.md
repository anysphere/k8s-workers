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
    `2026.09.03-a76a283` accepts that field.
    `cursor.com/install` currently installs `2026.09.10-fd3934a`, which reports
    `unrecognized_keys: workerReadyTimeoutSeconds` and never spawns.
  - `git` on `PATH` (required for git remotes / `--clone-git-repos`)
  - a workspace directory at `workerDir` (default `/workspace`)
- The controller container also needs `kubectl` on `PATH` (override
  `controller.image` if your worker image has `agent` but not `kubectl`)

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

Point `--spawn` at a script equivalent to the chart ConfigMap hook
(`chart/templates/configmap.yaml`). The in-cluster install remains the
supported long-running path.

## Monitoring

```bash
# Controller
kubectl -n cursord logs -l app.kubernetes.io/component=controller -f

# Worker Pods created by --spawn
kubectl -n cursord get pods -l app.kubernetes.io/component=worker

# Succeeded/Failed one-shot Pods stay until you delete them
kubectl -n cursord delete pod -l app.kubernetes.io/component=worker \
  --field-selector=status.phase=Succeeded
```

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
| `unrecognized_keys` / `workerReadyTimeoutSeconds` | Controller CLI is older than the pools response. Use a build that accepts that field (`2026.09.03-a76a283` does; `2026.09.10-fd3934a` from `cursor.com/install` does not) |
| Warm idle overshoots | Only one controller per pool; chart uses Recreate — avoid a second Helm release on the same pool with `warmIdle>0` |
| Controller CrashLoop | Controller image missing `kubectl` or `agent`; RBAC Role cannot create Pods; Secret key name ≠ `auth.secretKey` |

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
