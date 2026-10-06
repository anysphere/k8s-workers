# Changelog

Each release is a git tag named `v<version>`. While the chart is 0.x, a minor
release can need action from you, and its entry says what.

## 0.3.0

Opt-in session tokens with `auth.sessionToken` (default `false`), so worker
Pods no longer have to hold the long-lived service account key. With it on:

- The controller runs `agent worker controller --session-token` and is the
  only Pod with `CURSOR_API_KEY`.
- For each claim (and each wake), the spawn hook creates the worker Pod and
  then a Secret `tok-<worker-id>-<suffix>` owned by that Pod, holding a token
  that serves only that claim. Kubernetes deletes the Secret with the Pod.
- Worker Pods mount that Secret at `/var/run/cursor` and start with
  `--auth-token-file /var/run/cursor/token`. They get no `CURSOR_API_KEY`.
- The controller Role gains `create` on Secrets (no read, update, or delete)
  and `delete` on Pods, used only to remove a Pod whose Secret could not be
  created.

It works in claim mode only: `controller.warmIdle` must stay `0`, and the
chart fails the render otherwise.

Action needed only if you set `controller.extraArgs` to include
`--session-token` while `auth.sessionToken` is off: that left
`CURSOR_API_KEY` in every worker Pod, and the chart now refuses to render it.
Remove the flag from `controller.extraArgs` and set `auth.sessionToken=true`.

With `auth.sessionToken` off, the chart renders the same resources as 0.2.1
apart from the version labels and one comment in the spawn hook. As in
earlier releases, the upgrade restarts the controller Pod once; running worker
Pods keep running.

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
