# Releasing

The cloud-harness and agent-runtime teams own releases and `v*` tags.

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

## After the merge

Tag the merge commit with the new version and push the tag:

```bash
git fetch origin main
git tag -a v0.2.1 <merge-commit> -m "k8s-workers 0.2.1"
git push origin v0.2.1
```

Then create a GitHub release from the tag with its `CHANGELOG.md` entry as the
notes. Never move or delete a pushed tag; ship a new patch release instead.
