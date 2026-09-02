# cursor-worker-pool

Proof-of-concept Helm chart that runs an in-cluster `agent worker controller`
whose `--spawn` hook kubectl-creates Cursor self-hosted pool workers as
standalone Pods (`restartPolicy: Never`). It does **not** replace the published
[`worker-set-controller`](../worker-set-controller/chart/README.md) operator
chart.

Install docs, values, and the operator comparison live in
[chart/README.md](chart/README.md).

## Trademarks

Cursor and Anysphere are trademarks of Anysphere, Inc.
