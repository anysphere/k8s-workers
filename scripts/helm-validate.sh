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

# Decode the ConfigMap spawn hook, mock kubectl create, and kubeconform the Pod.
python3 - "${RENDER}" "${WORKDIR}" <<'PY'
from pathlib import Path
import sys

render = Path(sys.argv[1]).read_text()
workdir = Path(sys.argv[2])
marker = "  spawn-pod.sh: |"
idx = render.find(marker)
if idx < 0:
    raise SystemExit("rendered manifest missing spawn-pod.sh")
script_lines = []
for line in render[idx + len(marker) + 1 :].splitlines():
    if line == "":
        script_lines.append("")
        continue
    if line.startswith("    "):
        script_lines.append(line[4:])
        continue
    break
while script_lines and script_lines[-1] == "":
    script_lines.pop()
script = "\n".join(script_lines) + "\n"
if "kubectl create -f -" not in script or "restartPolicy: Never" not in script:
    raise SystemExit("spawn hook is not kubectl-creating a Never-restart Pod")
(workdir / "spawn-pod.sh").write_text(script)
PY

cat >"${WORKDIR}/kubectl" <<EOF
#!/bin/sh
if [ "\$1" = "create" ]; then
  cat >"${WORKDIR}/spawned-pod.yaml"
  echo "pod/mock created"
  exit 0
fi
echo "unexpected kubectl args: \$*" >&2
exit 1
EOF
chmod +x "${WORKDIR}/spawn-pod.sh" "${WORKDIR}/kubectl"

PATH="${WORKDIR}:${PATH}" \
  CURSOR_AGENT_WORKER_ID="ctrl-6e0d261c-86a2-4383-89f0-9162c1c10662" \
  CURSOR_POOL="gpu" \
  "${WORKDIR}/spawn-pod.sh" >"${WORKDIR}/spawn.out" 2>&1 || {
    cat "${WORKDIR}/spawn.out" >&2
    echo "spawn hook failed" >&2
    exit 1
  }
grep -F "kind: Pod" "${WORKDIR}/spawned-pod.yaml" >/dev/null
grep -F "restartPolicy: Never" "${WORKDIR}/spawned-pod.yaml" >/dev/null
grep -F "ctrl-6e0d261c-86a2-4383-89f0-9162c1c10662" "${WORKDIR}/spawned-pod.yaml" >/dev/null
if grep -F "CURSOR_API_ENDPOINT" "${WORKDIR}/spawned-pod.yaml"; then
  echo "spawned worker Pod includes CURSOR_API_ENDPOINT" >&2
  exit 1
fi
if grep -F "CURSOR_API_URL" "${WORKDIR}/spawned-pod.yaml"; then
  echo "spawned worker Pod includes CURSOR_API_URL" >&2
  exit 1
fi
if grep -F "https://api.cursor.com" "${WORKDIR}/spawned-pod.yaml"; then
  echo "spawned worker Pod includes https://api.cursor.com" >&2
  exit 1
fi
if grep -F "kind: Deployment" "${WORKDIR}/spawned-pod.yaml"; then
  echo "spawn hook must create a Pod, not a Deployment" >&2
  exit 1
fi

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
  kubeconform -strict -ignore-missing-schemas -summary "${WORKDIR}/spawned-pod.yaml"
fi

echo "helm-validate: ok"
