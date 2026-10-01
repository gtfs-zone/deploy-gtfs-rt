#!/bin/sh
# Renders the Kustomize trees; run by the pre-commit hook. The gtfs tree needs
# age.key to decrypt its secrets and is skipped without it.
set -e
cd "$(dirname "$0")/.."

if [ -f age.key ]; then
  SOPS_AGE_KEY_FILE="$PWD/age.key" \
    kustomize build --enable-alpha-plugins --enable-exec gtfs >/dev/null
else
  echo "check: no age.key, skipping the gtfs render" >&2
fi
kustomize build sites >/dev/null
