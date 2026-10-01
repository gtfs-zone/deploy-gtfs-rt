#!/usr/bin/env bash
# Checks the short-SHA tag deployed in this repo's manifests against the one
# ghcr.io's `latest` carries for each service image, and offers to bump the
# manifest to it. Needs `gh` logged in with the read:packages scope.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ORG=gtfs-zone
# Image name and GitHub repo name are the same for each service.
IMAGES=(
  gtfs-zone-rt-api
  gtfs-zone-rt-traccar-receiver
  gtfs-zone-rt-delay-estimator
  gtfs-zone-rt-pollers
  gtfs-zone-static-importer
)

for image in "${IMAGES[@]}"; do
  ref="ghcr.io/$ORG/$image"
  echo "== $image"

  files="$(grep -rl "$ref:" gtfs/ || true)"
  if [[ -z "$files" ]]; then
    echo "   no manifest references $ref, skipping"
    continue
  fi

  deployed_sha="$(grep -hoP "(?<=${ref//./\\.}:)[0-9a-f]{7}\b" $files | head -1)"

  # The short-SHA tag on the same version as `latest`.
  latest_sha="$(gh api "/orgs/$ORG/packages/container/$image/versions?per_page=100" \
    --jq '[.[] | .metadata.container.tags | select(index("latest")) | .[] | select(test("^[0-9a-f]{7}$"))][0] // empty')"
  if [[ -z "$latest_sha" ]]; then
    echo "   no short-SHA tag next to latest on $ref, skipping"
    continue
  fi

  if [[ "$deployed_sha" == "$latest_sha" ]]; then
    echo "   up to date ($deployed_sha)"
    continue
  fi

  echo "   deployed: $deployed_sha"
  echo "   latest:   $latest_sha"
  echo "   commits between deployed and latest:"
  gh api "repos/$ORG/$image/compare/$deployed_sha...$latest_sha" \
    --jq '.commits[] | "     \(.sha[0:7]) \(.commit.message | split("\n")[0])"' \
    || echo "     (compare failed)"

  read -r -p "   bump $image -> $latest_sha in $(echo "$files" | tr '\n' ' ')? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    for f in $files; do
      sed -i "s|$ref:$deployed_sha|$ref:$latest_sha|g" "$f"
    done
    echo "   bumped. review the diff and commit when ready."
  else
    echo "   skipped."
  fi
done
