# Changelog

Each release is a git tag named `v<version>`. While the chart is 0.x, a minor
release can need action from you, and its entry says what.

## 0.2.1

The first release you can install from a public registry, with no login:

```bash
helm install my-workers oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers --version 0.2.1
```

The chart renders the same resources as 0.2.0 except for the
`app.kubernetes.io/version` and `helm.sh/chart` labels. As with 0.2.0, the
label change restarts the controller Pod once on upgrade; running worker Pods
keep running.

## 0.2.0

First release, available as the `.tgz` attached to its GitHub release. Every
earlier commit on `main` also said `0.1.0`, so a `0.1.0` install could be any
of them. If you installed from `419a3a0`, the last untagged `main`, 0.2.0
renders the same resources except for the `app.kubernetes.io/version` and
`helm.sh/chart` labels. Those labels feed the controller's spawn-hook checksum,
so the upgrade restarts the controller Pod once; running worker Pods are not
part of the release and keep running.

Changes since the September 2 launch, for installs taken from an earlier
commit:

- Spawned worker Pods no longer inherit the controller's API endpoint
  (`CURSOR_API_ENDPOINT`, `CURSOR_API_URL`). Workers use the CLI default, and
  `controller.endpoint` now applies only to the controller.
- Worker Pods are created with `generateName` and named
  `<worker-id>-<suffix>`. Select them with the `cursor.com/worker-id` label
  instead of by name. Workers receive the claimed worker id unchanged in
  `CURSOR_AGENT_WORKER_ID`.
- The controller image needs `kubectl` and a POSIX shell; `python3` is no
  longer required.
- Opt-in workspace hibernation with `hibernation.enabled` (default `false`).
  With it off, the chart renders the same resources as before.
- The READMEs describe this chart as the replacement for the deprecated
  `worker-set-controller` operator.
