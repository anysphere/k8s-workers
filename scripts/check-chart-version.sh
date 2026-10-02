#!/usr/bin/env bash
# Fails when chart/ changed since the base ref without a version bump in
# chart/Chart.yaml, when appVersion differs from version, or when CHANGELOG.md
# has no entry for the version. chart/README.md changes need no bump.
#
# Usage: scripts/check-chart-version.sh [base-ref]   (default: origin/main)
set -euo pipefail

BASE="${1:-origin/main}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

fail() {
  echo "check-chart-version: $*" >&2
  exit 1
}

chart_field() {
  sed -n "s/^$1:[[:space:]]*//p" | tr -d "\"'" | head -n 1
}

version="$(chart_field version <chart/Chart.yaml)"
app_version="$(chart_field appVersion <chart/Chart.yaml)"

[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "chart/Chart.yaml version '${version}' is not MAJOR.MINOR.PATCH"
[[ "${app_version}" == "${version}" ]] ||
  fail "chart/Chart.yaml appVersion '${app_version}' must equal version '${version}'"
grep -Eq "^## ${version//./\\.}([[:space:]]|$)" CHANGELOG.md ||
  fail "CHANGELOG.md has no '## ${version}' entry"

merge_base="$(git merge-base "${BASE}" HEAD)" ||
  fail "no merge base with ${BASE}; fetch it first (git fetch origin main)"

changed="$(git diff --name-only "${merge_base}" HEAD -- chart ':(exclude)chart/README.md')"
if [[ -z "${changed}" ]]; then
  echo "check-chart-version: no chart changes since ${BASE}; version ${version}"
  exit 0
fi

base_version="$(git show "${merge_base}:chart/Chart.yaml" | chart_field version)"
newest="$(printf '%s\n%s\n' "${base_version}" "${version}" | sort -V | tail -n 1)"
if [[ "${version}" == "${base_version}" || "${newest}" != "${version}" ]]; then
  echo "Changed chart files:" >&2
  echo "${changed}" >&2
  fail "chart/ changed but version ${version} is not above ${base_version}. Bump version and appVersion in chart/Chart.yaml and add a CHANGELOG.md entry; see RELEASING.md."
fi

echo "check-chart-version: ${base_version} -> ${version}"
