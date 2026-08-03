#!/usr/bin/env bash
# Checks origin/main on sibling gtfs.zone repos against the SHA deployed in
# this repo's manifests, and offers to bump the manifest to the latest SHA.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REPOS=(cafe-car vehicle-poser trip-updogger hell-gate-bridge schedule-foamer)
SIBLINGS_DIR="$(realpath ..)"

for repo in "${REPOS[@]}"; do
  repo_path="$SIBLINGS_DIR/$repo"
  if [[ ! -d "$repo_path/.git" ]]; then
    echo "== $repo: skipping, no repo at $repo_path"
    continue
  fi

  echo "== $repo"
  git -C "$repo_path" fetch --quiet origin main
  remote_sha="$(git -C "$repo_path" rev-parse origin/main)"
  remote_short="${remote_sha:0:7}"

  files="$(grep -rl "git\.kcfam\.us/gtfs\.zone/$repo:" gtfs/ || true)"
  if [[ -z "$files" ]]; then
    echo "   no manifest references git.kcfam.us/gtfs.zone/$repo, skipping"
    continue
  fi

  deployed_sha="$(grep -hoP "(?<=git\.kcfam\.us/gtfs\.zone/$repo:)[0-9a-f]+" $files | head -1)"

  if [[ "$deployed_sha" == "$remote_short" ]]; then
    echo "   up to date ($deployed_sha)"
    continue
  fi

  echo "   deployed: $deployed_sha"
  echo "   origin/main: $remote_short"
  if git -C "$repo_path" cat-file -e "$deployed_sha" 2>/dev/null; then
    echo "   commits between deployed and origin/main:"
    git -C "$repo_path" log --oneline "$deployed_sha..$remote_sha" | sed 's/^/     /'
  fi

  read -r -p "   bump $repo -> $remote_short in $(echo "$files" | tr '\n' ' ')? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    for f in $files; do
      sed -i "s/git\.kcfam\.us\/gtfs\.zone\/$repo:$deployed_sha/git.kcfam.us\/gtfs.zone\/$repo:$remote_short/g" "$f"
    done
    echo "   bumped. review the diff and commit when ready."
  else
    echo "   skipped."
  fi
done
