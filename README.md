# cursor-worker-pool

Private proof-of-concept Helm sample for Self-Hosted Machines.

Runs an in-cluster `agent worker controller` whose `--spawn` hook
kubectl-creates pool workers as standalone Pods (`restartPolicy: Never`),
optionally with `--warm-idle`. It does **not** replace the published
Kubernetes operator path (`worker-set-controller` / `WorkerDeployment`).

Install docs, values, and the operator comparison live in
[chart/README.md](chart/README.md).

Extracted from everysphere Origin PR 1022748; not yet a public customer sample.

## Trademarks

Cursor and Anysphere are trademarks of Anysphere, Inc.
