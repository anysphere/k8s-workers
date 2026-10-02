#!/usr/bin/env bash
# Creates the GitHub release v<version> for chart/Chart.yaml at HEAD, with the
# version's CHANGELOG.md entry as notes and the packaged chart attached. Does
# nothing when the tag already exists, so merges that keep the version are
# no-ops.
#
# Usage: GH_TOKEN=... scripts/release-chart.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

fail() {
  echo "release-chart: $*" >&2
  exit 1
}

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

helm package chart --destination "${work}" >/dev/null
gh release create "${tag}" "${work}/k8s-workers-${version}.tgz" \
  --target "$(git rev-parse HEAD)" \
  --title "k8s-workers ${version}" \
  --notes-file "${work}/notes.md"

echo "release-chart: released ${tag}"
