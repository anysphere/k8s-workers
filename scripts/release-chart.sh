#!/usr/bin/env bash
# Publishes chart/Chart.yaml's version from HEAD: pushes the packaged chart to
# the OCI registry in CHART_REGISTRY, then creates the GitHub release
# v<version> with the version's CHANGELOG.md entry as notes and the package
# attached. Does nothing when the tag already exists, so merges that keep the
# version are no-ops. The tag is created last, so a failed push is retried on
# the next run.
#
# Usage: CHART_REGISTRY=oci://public.ecr.aws/<alias>/charts GH_TOKEN=... scripts/release-chart.sh
#        (log in to the registry with `helm registry login` first)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

fail() {
  echo "release-chart: $*" >&2
  exit 1
}

: "${CHART_REGISTRY:?set CHART_REGISTRY, e.g. oci://public.ecr.aws/k0i0n2g5/charts}"

version="$(sed -n 's/^version:[[:space:]]*//p' chart/Chart.yaml | tr -d "\"'" | head -n 1)"
tag="v${version}"

if [[ -n "$(git ls-remote --tags origin "refs/tags/${tag}")" ]]; then
  echo "release-chart: ${tag} already exists"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

awk -v v="${version}" '$1 == "##" { if (found) exit; found = ($2 == v); next } found' \
  CHANGELOG.md >"${work}/notes.md"
grep -q '[^[:space:]]' "${work}/notes.md" ||
  fail "CHANGELOG.md has no '## ${version}' entry"

package="${work}/k8s-workers-${version}.tgz"
helm package chart --destination "${work}" >/dev/null
helm push "${package}" "${CHART_REGISTRY}"
gh release create "${tag}" "${package}" \
  --target "$(git rev-parse HEAD)" \
  --title "k8s-workers ${version}" \
  --notes-file "${work}/notes.md"

echo "release-chart: released ${tag}"
