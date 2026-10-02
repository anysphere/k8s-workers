# Releasing

The cloud-harness and agent-runtime teams own releases. Merging a version bump
to `main` publishes it.

## In the pull request

Any change under `chart/` other than `chart/README.md` ships as a new version.
In the same PR, raise `version` in `chart/Chart.yaml`, set `appVersion` to the
same value, and add a `## <version>` entry at the top of `CHANGELOG.md` that
says what changed and what users must do, if anything. CI runs
`scripts/check-chart-version.sh` and fails the PR when any of these is missing.

Pick the number by what an existing install needs:

- Minor (0.2.x to 0.3.0) when a user may need to act: a value is renamed or
  removed, a default changes, a new value becomes required, or rendered
  resource names or labels change.
- Patch (0.2.0 to 0.2.1) for everything else, including fixes and new optional
  values whose defaults render the same resources.

## On merge

The `release` job in CI runs `scripts/release-chart.sh` on every push to
`main`. When no `v<version>` tag exists yet, it pushes the chart to
`oci://ghcr.io/anysphere/charts/k8s-workers`, then tags the merge commit and
creates a GitHub release with the version's `CHANGELOG.md` entry as notes and
`k8s-workers-<version>.tgz` attached. Merges that keep the version do nothing.

Never move, delete, or overwrite a published version; ship a new patch release
instead.
