#!/usr/bin/env bash
# End-to-end smoke test for the chart on a local kind cluster.
#
# Nothing here talks to Cursor. scripts/stub-agent/ stands in for the `agent`
# CLI so the chart's mechanics run for real against a Kubernetes API server:
#   controller Deployment -> /hooks/spawn-pod.sh -> in-cluster kubectl create
#   (chart RBAC) -> worker Pod readiness probes -> idle exit -> Succeeded,
# then a helm upgrade from warm-idle to claim-then-spawn.
#
# Requires docker, kind, kubectl, helm, and jq. Set KEEP_CLUSTER=1 to leave a
# cluster this script created running for inspection; a pre-existing cluster
# named KIND_CLUSTER is reused and never deleted.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${ROOT}/chart"
CLUSTER="${KIND_CLUSTER:-k8s-workers-e2e}"
NAMESPACE="cursord-e2e"
RELEASE="e2e"
IMAGE="k8s-workers-stub-agent:e2e"
IDLE_SECONDS=20

for tool in docker kind kubectl helm jq; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "kind-e2e: ${tool} not found on PATH" >&2
    exit 127
  fi
done

WORKDIR="$(mktemp -d)"
export KUBECONFIG="${WORKDIR}/kubeconfig"
CREATED_CLUSTER=0
cleanup() {
  if [ "${CREATED_CLUSTER}" = "1" ] && [ "${KEEP_CLUSTER:-0}" != "1" ]; then
    kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
    rm -rf "${WORKDIR}"
  else
    echo "kind-e2e: cluster ${CLUSTER} left running; export KUBECONFIG=${KUBECONFIG}" >&2
  fi
}
trap cleanup EXIT

fail() {
  echo "kind-e2e: $*" >&2
  exit 1
}
k() { kubectl -n "${NAMESPACE}" "$@"; }

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "kind-e2e: reusing kind cluster ${CLUSTER}"
else
  kind create cluster --name "${CLUSTER}" --wait 180s
  CREATED_CLUSTER=1
fi
kind get kubeconfig --name "${CLUSTER}" >"${KUBECONFIG}"
chmod 600 "${KUBECONFIG}"

# Build the stub image with the cluster's own kubectl so client/server match.
docker cp "${CLUSTER}-control-plane:/usr/bin/kubectl" "${WORKDIR}/kubectl"
cp "${ROOT}/scripts/stub-agent/Dockerfile" "${ROOT}/scripts/stub-agent/agent" "${WORKDIR}/"
docker build -q -t "${IMAGE}" "${WORKDIR}" >/dev/null
kind load docker-image "${IMAGE}" --name "${CLUSTER}" >/dev/null

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
k create secret generic cursor-workers-api-key --from-literal=api-key=not-a-real-key \
  --dry-run=client -o yaml | k apply -f - >/dev/null

# A reused cluster may hold a release and one-shot Pods from an earlier run.
if helm status "${RELEASE}" --namespace "${NAMESPACE}" >/dev/null 2>&1; then
  helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait >/dev/null
fi
k delete pod -l app.kubernetes.io/component=worker --ignore-not-found --wait >/dev/null

helm upgrade --install "${RELEASE}" "${CHART}" --namespace "${NAMESPACE}" \
  --set image.repository="${IMAGE%%:*}" \
  --set image.tag="${IMAGE##*:}" \
  --set image.pullPolicy=Never \
  --set pool=default \
  --set controller.warmIdle=2 \
  --set auth.existingSecret=cursor-workers-api-key \
  --set idleReleaseTimeout="${IDLE_SECONDS}" \
  --set labels[0]=team=e2e \
  --set probes.readiness.initialDelaySeconds=2 \
  --set probes.liveness.initialDelaySeconds=5 >/dev/null

CONTROLLER="deploy/${RELEASE}-k8s-workers"
SA="system:serviceaccount:${NAMESPACE}:${RELEASE}-k8s-workers"
k rollout status "${CONTROLLER}" --timeout=120s

wait_for_workers() {
  local want="$1" have=0 i
  for i in $(seq 1 60); do
    have="$(k get pods -l app.kubernetes.io/component=worker -o name | wc -l | tr -d ' ')"
    if [ "${have}" -ge "${want}" ]; then
      return 0
    fi
    sleep 2
  done
  k logs -l app.kubernetes.io/component=controller --tail=50 >&2 || true
  fail "expected ${want} worker Pods, found ${have}"
}

echo "kind-e2e: warm-idle=2 -> waiting for spawned worker Pods"
wait_for_workers 2
k wait --for=condition=Ready pod -l app.kubernetes.io/component=worker --timeout=120s >/dev/null

POD="$(k get pods -l app.kubernetes.io/component=worker -o jsonpath='{.items[0].metadata.name}')"
SPEC="$(k get pod "${POD}" -o json)"
assert_pod() {
  if [ "$(printf '%s' "${SPEC}" | jq -r "$1")" != "true" ]; then
    fail "spawned Pod ${POD}: assertion failed: $1"
  fi
}
assert_pod '.spec.restartPolicy == "Never"'
assert_pod '.spec.automountServiceAccountToken == false'
assert_pod '.metadata.labels["app.kubernetes.io/component"] == "worker"'
assert_pod ".spec.containers[0].args == [\"worker\",\"--pool\",\"default\",\"--idle-release-timeout\",\"${IDLE_SECONDS}\",\"--worker-dir\",\"/workspace\",\"--management-addr\",\"0.0.0.0:8080\",\"--label\",\"team=e2e\",\"start\"]"
assert_pod '(.spec.containers[0].env | map(select(.name == "CURSOR_API_KEY"))[0].valueFrom.secretKeyRef.name) == "cursor-workers-api-key"'
assert_pod '(.spec.containers[0].env | map(select(.name == "CURSOR_POOL"))[0].value) == "default"'
# generateName: the Pod is <worker-id>-<suffix>; the worker gets the raw id.
assert_pod '(.spec.containers[0].env | map(select(.name == "CURSOR_AGENT_WORKER_ID"))[0].value) as $id | ($id | startswith("ctrl-")) and (.metadata.name | startswith($id + "-")) and (.metadata.name != $id)'
assert_pod '(.spec.containers[0].env | map(select(.name == "CURSOR_AGENT_WORKER_ID"))[0].value) == .metadata.annotations["cursor.com/worker-id"]'
assert_pod '(.spec.containers[0].env | map(select(.name == "CURSOR_WORKER_NAME"))[0].valueFrom.fieldRef.fieldPath) == "metadata.name"'
assert_pod '(.spec.containers[0].env | map(select(.name == "CURSOR_API_ENDPOINT")) | length) == 0'

# The controller ServiceAccount creates Pods and nothing more.
[ "$(k auth can-i create pods --as="${SA}")" = "yes" ] || fail "controller SA cannot create pods"
[ "$(k auth can-i delete pods --as="${SA}")" = "no" ] || fail "controller SA should not delete pods"
[ "$(k auth can-i patch deployments --as="${SA}")" = "no" ] || fail "controller SA should not patch deployments"

# Hibernation is off by default: no claims, no CronJob, no PVC rights, no volume.
[ "$(k auth can-i create persistentvolumeclaims --as="${SA}")" = "no" ] || fail "hibernation off must not grant PVC create"
[ -z "$(k get pvc -o name)" ] || fail "hibernation off must not create PVCs"
[ -z "$(k get cronjob -o name)" ] || fail "hibernation off must not render a CronJob"
assert_pod '(.spec.volumes // []) | length == 0'
assert_pod '.spec.containers[0].command == ["agent"]'

echo "kind-e2e: waiting ${IDLE_SECONDS}s for idle release -> Succeeded"
k wait --for=jsonpath='{.status.phase}'=Succeeded pod -l app.kubernetes.io/component=worker --timeout=120s >/dev/null
RESTARTS="$(k get pods -l app.kubernetes.io/component=worker \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | sort -u)"
[ "${RESTARTS}" = "0" ] || fail "worker Pods restarted after idle exit: ${RESTARTS}"
CONTROLLER_RESTARTS="$(k get pods -l app.kubernetes.io/component=controller \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')"
[ "${CONTROLLER_RESTARTS}" = "0" ] || fail "controller restarted ${CONTROLLER_RESTARTS} times"
k delete pod -l app.kubernetes.io/component=worker --field-selector=status.phase=Succeeded >/dev/null

echo "kind-e2e: upgrade to warm-idle=0 (claim-then-spawn)"
helm upgrade "${RELEASE}" "${CHART}" --namespace "${NAMESPACE}" --reuse-values \
  --set controller.warmIdle=0 >/dev/null
k rollout status "${CONTROLLER}" --timeout=120s
ARGS="$(k get "${CONTROLLER}" -o jsonpath='{.spec.template.spec.containers[0].args}')"
case "${ARGS}" in
  *--warm-idle*) fail "warmIdle=0 must omit --warm-idle: ${ARGS}" ;;
esac
wait_for_workers 1
k wait --for=condition=Ready pod -l app.kubernetes.io/component=worker --timeout=120s >/dev/null

helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait >/dev/null
k delete pod -l app.kubernetes.io/component=worker --ignore-not-found --wait >/dev/null

# ---------------------------------------------------------------------------
# Hibernation on. Same stub image; the reaper schedule is set to a date that
# never comes so only the manual trigger below runs it.
echo "kind-e2e: hibernation.enabled=true -> warm-idle=1"
HIB_RELEASE="${RELEASE}-hib"
HIB_CONTROLLER="deploy/${HIB_RELEASE}-k8s-workers"
HIB_SA="system:serviceaccount:${NAMESPACE}:${HIB_RELEASE}-k8s-workers"
REAPER="${HIB_RELEASE}-k8s-workers-reaper"
helm upgrade --install "${HIB_RELEASE}" "${CHART}" --namespace "${NAMESPACE}" \
  --set image.repository="${IMAGE%%:*}" \
  --set image.tag="${IMAGE##*:}" \
  --set image.pullPolicy=Never \
  --set pool=default \
  --set controller.warmIdle=1 \
  --set auth.existingSecret=cursor-workers-api-key \
  --set idleReleaseTimeout="${IDLE_SECONDS}" \
  --set probes.readiness.initialDelaySeconds=2 \
  --set probes.liveness.initialDelaySeconds=5 \
  --set hibernation.enabled=true \
  --set hibernation.size=1Gi \
  --set hibernation.seed.fromPath=/opt/seed \
  --set hibernation.pvcTtl=1s \
  --set hibernation.podTtl=1s \
  --set 'hibernation.reaper.schedule=0 0 31 2 *' >/dev/null
k rollout status "${HIB_CONTROLLER}" --timeout=120s

wait_for_workers 1
k wait --for=condition=Ready pod -l app.kubernetes.io/component=worker --timeout=180s >/dev/null
POD="$(k get pods -l app.kubernetes.io/component=worker -o jsonpath='{.items[0].metadata.name}')"
SPEC="$(k get pod "${POD}" -o json)"
WORKER_ID="$(printf '%s' "${SPEC}" | jq -r '.spec.containers[0].env[] | select(.name == "CURSOR_AGENT_WORKER_ID") | .value')"
PVC="ws-${WORKER_ID}"
assert_pod '.spec.restartPolicy == "Never"'
assert_pod '.spec.containers[0].command == ["/bin/sh", "/cursor-hooks/entrypoint.sh"]'
assert_pod '.spec.containers[0].args[0:2] == ["agent", "worker"]'
assert_pod "(.spec.volumes[] | select(.name == \"workspace\") | .persistentVolumeClaim.claimName) == \"${PVC}\""
assert_pod '(.spec.containers[0].volumeMounts[] | select(.name == "workspace" and .subPath == "workspace") | .mountPath) == "/workspace"'
assert_pod '([.spec.containers[0].volumeMounts[] | select(.subPath == "home")] | length) == 0'
[ "$(k get pvc "${PVC}" -o jsonpath='{.status.phase}')" = "Bound" ] || fail "${PVC} is not Bound"
[ -n "$(k get pvc "${PVC}" -o jsonpath='{.metadata.annotations.cursor\.com/last-used-epoch}')" ] || fail "${PVC} missing last-used-epoch"
[ "$(k get pvc "${PVC}" -o jsonpath='{.metadata.labels.cursor\.com/worker-id}')" = "${WORKER_ID}" ] || fail "${PVC} missing worker-id label"
[ "$(k auth can-i create persistentvolumeclaims --as="${HIB_SA}")" = "yes" ] || fail "controller SA cannot create PVCs"
[ "$(k auth can-i patch persistentvolumeclaims --as="${HIB_SA}")" = "yes" ] || fail "controller SA cannot patch PVCs"
[ "$(k auth can-i delete persistentvolumeclaims --as="${HIB_SA}")" = "no" ] || fail "controller SA should not delete PVCs"
[ "$(k auth can-i delete persistentvolumeclaims --as="system:serviceaccount:${NAMESPACE}:${REAPER}")" = "yes" ] || fail "reaper SA cannot delete PVCs"
k get cronjob "${REAPER}" >/dev/null || fail "reaper CronJob missing"
LOGS="$(k logs "${POD}")"
case "${LOGS}" in *"seeding /workspace from /opt/seed"*) ;; *) fail "entrypoint did not seed the empty volume: ${LOGS}" ;; esac
case "${LOGS}" in *"prior episodes in workspace: 0"*) ;; *) fail "first episode should see no prior markers: ${LOGS}" ;; esac
case "${LOGS}" in *"SEED.txt"*) ;; *) fail "seeded file missing from workspace: ${LOGS}" ;; esac

echo "kind-e2e: waiting ${IDLE_SECONDS}s for idle release with the claim kept"
k wait --for=jsonpath='{.status.phase}'=Succeeded pod "${POD}" --timeout=120s >/dev/null
[ "$(k get pvc "${PVC}" -o jsonpath='{.status.phase}')" = "Bound" ] || fail "${PVC} should survive the idle exit"

# Wake: run the hook inside the controller exactly as the controller would,
# with CURSOR_WAKE=1 and the claimed worker id.
echo "kind-e2e: wake ${WORKER_ID} via the spawn hook"
k exec "${HIB_CONTROLLER}" -- env CURSOR_WAKE=1 "CURSOR_AGENT_WORKER_ID=${WORKER_ID}" CURSOR_POOL=default \
  /hooks/spawn-pod.sh >/dev/null
wait_for_workers 2
WAKE_POD="$(k get pods -l app.kubernetes.io/component=worker --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
[ "${WAKE_POD}" != "${POD}" ] || fail "wake did not create a new Pod"
k wait --for=condition=Ready pod "${WAKE_POD}" --timeout=180s >/dev/null
SPEC="$(k get pod "${WAKE_POD}" -o json)"
assert_pod "(.spec.containers[0].env[] | select(.name == \"CURSOR_AGENT_WORKER_ID\") | .value) == \"${WORKER_ID}\""
assert_pod "(.spec.volumes[] | select(.name == \"workspace\") | .persistentVolumeClaim.claimName) == \"${PVC}\""
LOGS="$(k logs "${WAKE_POD}")"
case "${LOGS}" in *"already populated; resuming"*) ;; *) fail "wake did not resume the populated volume: ${LOGS}" ;; esac
case "${LOGS}" in *"prior episodes in workspace: 1"*) ;; *) fail "wake did not see the previous episode's files: ${LOGS}" ;; esac
k wait --for=jsonpath='{.status.phase}'=Succeeded pod "${WAKE_POD}" --timeout=120s >/dev/null

# Reaper: TTLs are 1s, so one run removes the finished Pods and the claim.
echo "kind-e2e: trigger the reaper"
k create job --from="cronjob/${REAPER}" e2e-reap >/dev/null
k wait --for=condition=complete "job/e2e-reap" --timeout=120s >/dev/null || {
  k logs "job/e2e-reap" >&2 || true
  fail "reaper job did not complete"
}
for i in $(seq 1 30); do
  if [ -z "$(k get pvc "${PVC}" -o name 2>/dev/null)" ] && [ -z "$(k get pods -l "cursor.com/worker-id=${WORKER_ID}" -o name)" ]; then
    break
  fi
  sleep 2
done
[ -z "$(k get pvc "${PVC}" -o name 2>/dev/null)" ] || { k logs "job/e2e-reap" >&2; fail "reaper left ${PVC} behind"; }
[ -z "$(k get pods -l "cursor.com/worker-id=${WORKER_ID}" -o name)" ] || fail "reaper left finished Pods behind"

# Wake after the claim is gone: exit 3 and no Pod, so the window can lapse.
echo "kind-e2e: wake with the claim gone must not spawn"
rc=0
k exec "${HIB_CONTROLLER}" -- env CURSOR_WAKE=1 "CURSOR_AGENT_WORKER_ID=${WORKER_ID}" CURSOR_POOL=default \
  /hooks/spawn-pod.sh >/dev/null 2>&1 || rc=$?
[ "${rc}" = "3" ] || fail "expected exit 3 from a wake without its PVC, got ${rc}"
[ -z "$(k get pods -l "cursor.com/worker-id=${WORKER_ID}" -o name)" ] || fail "a wake without its PVC must not create a Pod"

helm uninstall "${HIB_RELEASE}" --namespace "${NAMESPACE}" >/dev/null
echo "kind-e2e: ok"
