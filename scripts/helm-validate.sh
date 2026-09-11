#!/usr/bin/env bash
# Render/lint checks for the k8s-workers chart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${ROOT}/chart"

helm lint "${CHART}" \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=test \
  --set auth.existingSecret=cursor-workers-api-key

expect_fail() {
  local label="$1"
  shift
  local err
  err="$(mktemp)"
  if helm template test-release "${CHART}" "$@" >/dev/null 2>"${err}"; then
    echo "expected failure: ${label}" >&2
    cat "${err}" >&2 || true
    rm -f "${err}"
    exit 1
  fi
  rm -f "${err}"
}

must_contain() {
  local needle="$1"
  if ! grep -F -- "${needle}" "${RENDER}" >/dev/null; then
    echo "rendered manifest missing: ${needle}" >&2
    exit 1
  fi
}

must_not_contain() {
  local needle="$1"
  if grep -F -- "${needle}" "${RENDER}" >/dev/null; then
    echo "rendered manifest should not contain: ${needle}" >&2
    exit 1
  fi
}

expect_fail "no image repository" \
  --set auth.existingSecret=cursor-workers-api-key
expect_fail "no auth" \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=test
expect_fail "warmIdle without controller" \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=test \
  --set auth.existingSecret=cursor-workers-api-key \
  --set controller.enabled=false \
  --set controller.warmIdle=2
expect_fail "controller without service-account token" \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=test \
  --set auth.existingSecret=cursor-workers-api-key \
  --set controller.enabled=true \
  --set serviceAccount.automount=false

WORKDIR="$(mktemp -d)"
RENDER="${WORKDIR}/render.yaml"
SECRET_RENDER="${WORKDIR}/secret.yaml"
WARM_RENDER="${WORKDIR}/warm.yaml"
trap 'rm -rf "${WORKDIR}"' EXIT

helm template test-release "${CHART}" \
  --namespace cursord \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=test \
  --set pool=gpu \
  --set idleReleaseTimeout=600 \
  --set workerDir=/workspace \
  --set managementAddr=0.0.0.0:8080 \
  --set labels[0]=team=backend \
  --set auth.existingSecret=cursor-workers-api-key \
  >"${RENDER}"

must_contain "kind: Deployment"
must_contain "kind: ServiceAccount"
must_contain "kind: ConfigMap"
must_contain "kind: Role"
must_contain "kind: RoleBinding"
must_contain "replicas: 1"
must_contain "example.local/cursor-worker:test"
must_contain "worker"
must_contain "controller"
must_contain "--spawn"
must_contain "/hooks/spawn-pod.sh"
must_contain "kubectl create"
must_contain "restartPolicy: Never"
must_contain "--pool"
must_contain "gpu"
must_contain "--idle-release-timeout"
must_contain "--worker-dir"
must_contain "--management-addr"
must_contain "--label"
must_contain "team=backend"
must_contain "CURSOR_API_KEY"
must_contain "cursor-workers-api-key"
must_contain "/readyz"
must_contain "/healthz"
must_contain "containerPort: 8080"
must_contain "app.kubernetes.io/component: worker"
must_contain "app.kubernetes.io/component: controller"
must_not_contain "--warm-idle"
must_not_contain "kind: HorizontalPodAutoscaler"
must_not_contain "kind: WorkerDeployment"
must_not_contain "kind: CustomResourceDefinition"

if grep -E "^kind: Pod$" "${RENDER}"; then
  echo "Helm release must not include a static worker Pod; spawn creates Pods at runtime" >&2
  exit 1
fi
if grep -F "kind: Secret" "${RENDER}"; then
  echo "existingSecret should not create a Secret" >&2
  exit 1
fi

# Extract every key of the spawn ConfigMap into a hooks dir (the hook reads
# its sibling manifests relative to $0), then run the hook against a mock
# kubectl that records what it was asked to create.
extract_hooks() {
  local render="$1" dest="$2"
  mkdir -p "${dest}"
  python3 - "${render}" "${dest}" <<'PY'
from pathlib import Path
import re
import sys

render = Path(sys.argv[1]).read_text()
dest = Path(sys.argv[2])
docs = [d for d in render.split("\n---") if "kind: ConfigMap" in d and "spawn-pod.sh: |" in d]
if len(docs) != 1:
    raise SystemExit("expected exactly one spawn ConfigMap in the render")
lines = docs[0].splitlines()
start = lines.index("data:")
key, body = None, []
def flush():
    if key is not None:
        while body and body[-1] == "":
            body.pop()
        (dest / key).write_text("\n".join(body) + "\n")
for line in lines[start + 1 :]:
    m = re.match(r"^  ([A-Za-z0-9._-]+): \|$", line)
    if m:
        flush()
        key, body = m.group(1), []
        continue
    if key is None:
        raise SystemExit(f"unexpected line under data: {line!r}")
    if line == "":
        body.append("")
    elif line.startswith("    "):
        body.append(line[4:])
    else:
        break
flush()
if not (dest / "spawn-pod.sh").exists() or not (dest / "worker-pod.yaml").exists():
    raise SystemExit("spawn ConfigMap must carry spawn-pod.sh and worker-pod.yaml")
PY
  chmod +x "${dest}/spawn-pod.sh"
  if ! grep -F "kubectl create -f -" "${dest}/spawn-pod.sh" >/dev/null \
    || ! grep -F "restartPolicy: Never" "${dest}/worker-pod.yaml" >/dev/null; then
    echo "spawn hook is not kubectl-creating a Never-restart Pod" >&2
    exit 1
  fi
}

# Mock kubectl. `create` records each manifest as created-N.yaml in MOCK_DIR.
# `get pvc` answers from MOCK_PVC_STATE: empty means NotFound, otherwise the
# jsonpath the hook asks for ("Bound/" bound, "Bound/<ts>" terminating).
# `annotate` is recorded in annotate.log.
cat >"${WORKDIR}/kubectl" <<'EOF'
#!/bin/sh
case "$1" in
  create)
    n=$(ls "${MOCK_DIR}" | grep -c '^created-' || true)
    cat >"${MOCK_DIR}/created-$((n + 1)).yaml"
    echo "mock/created"
    ;;
  -n)
    shift 2
    case "$1" in
      get)
        if [ -z "${MOCK_PVC_STATE:-}" ]; then
          echo "Error from server (NotFound): persistentvolumeclaims \"$3\" not found" >&2
          exit 1
        fi
        printf '%s' "${MOCK_PVC_STATE}"
        ;;
      annotate)
        echo "$*" >>"${MOCK_DIR}/annotate.log"
        ;;
      *)
        echo "unexpected kubectl args: -n ... $*" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected kubectl args: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${WORKDIR}/kubectl"

WORKER_ID="ctrl-6e0d261c-86a2-4383-89f0-9162c1c10662"
run_hook() { # label hooks_dir mock_dir [ENV=val ...]
  local label="$1" hooks="$2" mock="$3"
  shift 3
  mkdir -p "${mock}"
  if ! env -i PATH="${WORKDIR}:${PATH}" MOCK_DIR="${mock}" \
    CURSOR_AGENT_WORKER_ID="${WORKER_ID}" CURSOR_POOL="gpu" "$@" \
    "${hooks}/spawn-pod.sh" >"${mock}/hook.out" 2>&1; then
    cat "${mock}/hook.out" >&2
    echo "spawn hook failed: ${label}" >&2
    exit 1
  fi
}
expect_hook_fail() { # label hooks_dir mock_dir expected_exit [ENV=val ...]
  local label="$1" hooks="$2" mock="$3" want="$4" rc=0
  shift 4
  mkdir -p "${mock}"
  env -i PATH="${WORKDIR}:${PATH}" MOCK_DIR="${mock}" \
    CURSOR_AGENT_WORKER_ID="${WORKER_ID}" CURSOR_POOL="gpu" "$@" \
    "${hooks}/spawn-pod.sh" >"${mock}/hook.out" 2>&1 || rc=$?
  if [ "${rc}" != "${want}" ]; then
    cat "${mock}/hook.out" >&2
    echo "expected exit ${want} from spawn hook (${label}), got ${rc}" >&2
    exit 1
  fi
  if ls "${mock}" | grep -q '^created-'; then
    echo "spawn hook must not create anything when it fails (${label})" >&2
    exit 1
  fi
}
created_count() { ls "$1" | grep -c '^created-' || true; }
file_contains() { grep -F -- "$2" "$1" >/dev/null || { echo "$1 missing: $2" >&2; exit 1; }; }
file_lacks() { if grep -F -- "$2" "$1" >/dev/null; then echo "$1 should not contain: $2" >&2; exit 1; fi; }

extract_hooks "${RENDER}" "${WORKDIR}/hooks-off"
for k in spawn-pod.sh worker-pod.yaml; do
  file_lacks "${WORKDIR}/hooks-off/${k}" "python3"
done
file_lacks "${WORKDIR}/hooks-off/worker-pod.yaml" "kind: PersistentVolumeClaim"
file_lacks "${WORKDIR}/hooks-off/worker-pod.yaml" "persistentVolumeClaim"

# Hibernation off, no wake: today's behavior with a collision-safe name.
run_hook "off/no-wake" "${WORKDIR}/hooks-off" "${WORKDIR}/off-nowake"
[ "$(created_count "${WORKDIR}/off-nowake")" = "1" ] || { echo "off/no-wake must create exactly one object" >&2; exit 1; }
SPAWNED="${WORKDIR}/off-nowake/created-1.yaml"
file_contains "${SPAWNED}" "kind: Pod"
file_contains "${SPAWNED}" "restartPolicy: Never"
file_contains "${SPAWNED}" "generateName: \"${WORKER_ID}-\""
file_contains "${SPAWNED}" "value: \"${WORKER_ID}\""
file_contains "${SPAWNED}" "cursor.com/worker-id: \"${WORKER_ID}\""
file_contains "${SPAWNED}" "fieldPath: metadata.name"
file_contains "${SPAWNED}" "value: \"gpu\""
file_lacks "${SPAWNED}" "  name: ${WORKER_ID}"
file_lacks "${SPAWNED}" "CURSOR_API_ENDPOINT"
file_lacks "${SPAWNED}" "CURSOR_API_URL"
file_lacks "${SPAWNED}" "https://api.cursor.com"
file_lacks "${SPAWNED}" "kind: Deployment"
file_lacks "${SPAWNED}" "persistentVolumeClaim"
file_lacks "${SPAWNED}" "entrypoint.sh"
[ ! -e "${WORKDIR}/off-nowake/annotate.log" ] || { echo "off mode must not annotate" >&2; exit 1; }

# Hibernation off, wake: a fresh Pod with the claimed id and no volume.
run_hook "off/wake" "${WORKDIR}/hooks-off" "${WORKDIR}/off-wake" CURSOR_WAKE=1
[ "$(created_count "${WORKDIR}/off-wake")" = "1" ] || { echo "off/wake must create exactly one object" >&2; exit 1; }
file_contains "${WORKDIR}/off-wake/created-1.yaml" "kind: Pod"
file_contains "${WORKDIR}/off-wake/created-1.yaml" "value: \"${WORKER_ID}\""
file_lacks "${WORKDIR}/off-wake/created-1.yaml" "persistentVolumeClaim"

# A $ in a custom command must survive substitution untouched, and a mixed-case
# id must slug to a DNS-1123 name while reaching the worker verbatim.
helm template test-release "${CHART}" \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=test \
  --set auth.existingSecret=cursor-workers-api-key \
  --set 'command[0]=/bin/sh' --set 'command[1]=-c' --set 'command[2]=exec "$AGENT_BIN" "$@"' \
  >"${WORKDIR}/dollar.yaml"
extract_hooks "${WORKDIR}/dollar.yaml" "${WORKDIR}/hooks-dollar"
mkdir -p "${WORKDIR}/dollar"
env -i PATH="${WORKDIR}:${PATH}" MOCK_DIR="${WORKDIR}/dollar" \
  CURSOR_AGENT_WORKER_ID="Ctrl_ABC.def" CURSOR_POOL="gpu" \
  "${WORKDIR}/hooks-dollar/spawn-pod.sh" >/dev/null 2>&1
file_contains "${WORKDIR}/dollar/created-1.yaml" 'exec "$AGENT_BIN" "$@"'
file_contains "${WORKDIR}/dollar/created-1.yaml" 'generateName: "ctrl-abc-def-"'
file_contains "${WORKDIR}/dollar/created-1.yaml" 'value: "Ctrl_ABC.def"'
expect_hook_fail "unsafe worker id" "${WORKDIR}/hooks-off" "${WORKDIR}/unsafe-id" 1 \
  CURSOR_AGENT_WORKER_ID='ctrl-1; rm -rf /'
expect_hook_fail "unsafe pool" "${WORKDIR}/hooks-off" "${WORKDIR}/unsafe-pool" 1 \
  CURSOR_POOL='gpu|x'

# Controller enabled is the default; an explicit true must still render.
helm template test-release "${CHART}" \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=test \
  --set auth.existingSecret=cursor-workers-api-key \
  --set controller.enabled=true \
  --set controller.warmIdle=3 \
  >"${WARM_RENDER}"
grep -F -- "--warm-idle" "${WARM_RENDER}" >/dev/null
grep -A1 -- "--warm-idle" "${WARM_RENDER}" | grep -F '"3"' >/dev/null
if grep -E "^kind: Pod$" "${WARM_RENDER}"; then
  echo "warm-idle render must not include a static worker Pod" >&2
  exit 1
fi
if grep -F "kind: HorizontalPodAutoscaler" "${WARM_RENDER}"; then
  echo "chart must not render HPA" >&2
  exit 1
fi

helm template test-release "${CHART}" \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=test \
  --set auth.apiKey=test-not-a-real-key \
  >"${SECRET_RENDER}"
grep -F "kind: Secret" "${SECRET_RENDER}" >/dev/null

# Suffixed resource names must stay within DNS-1123 (63) when fullname is maxed.
LONG_RENDER="${WORKDIR}/long.yaml"
helm template test-release "${CHART}" \
  --set fullnameOverride=abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk \
  --set image.repository=example.local/cursor-worker \
  --set image.tag=test \
  --set auth.apiKey=test-not-a-real-key \
  >"${LONG_RENDER}"
python3 - "${LONG_RENDER}" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
names = re.findall(r"(?m)^  name: (.+)$", text)
if not names:
    raise SystemExit("long-name render produced no metadata.names")
for name in names:
    if len(name) > 63:
        raise SystemExit(f"resource name exceeds 63 chars: {name!r} ({len(name)})")
    if name.endswith("-"):
        raise SystemExit(f"resource name must not end with '-': {name!r}")
if not any(n.endswith("-spawn") for n in names):
    raise SystemExit("expected a *-spawn ConfigMap name in the long-name render")
if not any(n.endswith("-api-key") for n in names):
    raise SystemExit("expected a *-api-key Secret name in the long-name render")
PY

if command -v kubeconform >/dev/null 2>&1; then
  kubeconform -strict -ignore-missing-schemas -summary "${RENDER}"
  kubeconform -strict -ignore-missing-schemas -summary "${WARM_RENDER}"
  kubeconform -strict -ignore-missing-schemas -summary "${SECRET_RENDER}"
  kubeconform -strict -ignore-missing-schemas -summary "${SPAWNED}"
fi

echo "helm-validate: ok"
