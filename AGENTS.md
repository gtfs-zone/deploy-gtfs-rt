# AGENTS.md

Deploys the gtfs.zone stack onto a single-node k3s cluster, managed entirely by
ArgoCD watching this repo (app-of-apps). There is no deploy step: change YAML,
commit, push, and ArgoCD reconciles.

## Commands

```bash
# Render the tree the way ArgoCD's KSOPS plugin does; run before every commit
PATH="$HOME/.local/bin:$PATH" SOPS_AGE_KEY_FILE=$PWD/age.key \
  kustomize build --enable-alpha-plugins --enable-exec gtfs

# Validate a Helm value change against the real chart
helm template <release> <repo>/<chart> --version <v> -n <ns> -f infra/<comp>/values.yaml

# kubectl runs on the node; the KUBECONFIG export is required
ssh kcfam 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n argocd get pods'
```

## Architecture

`apps/` holds one ArgoCD `Application` per file (`root.yaml` is the root),
`infra/` the platform Helm values, `gtfs/` the application stack (Kustomize +
SOPS secrets) and `sites/` the nginx-served sites. Details:

- [docs/architecture.md](docs/architecture.md): layout, edge, ingest and service map
- [docs/operations.md](docs/operations.md): cluster access, ArgoCD, Gatus,
  migrations, adding auth or a hostname, Traccar config
- [docs/traps.md](docs/traps.md): traps that have already bitten, and known gaps.
  Read it before touching Keycloak, Traefik, Garage, Dagster or a Helm chart.
- [README.md](README.md): diagrams and the from-scratch bootstrap

Invariants:

- **No `apply`**. ArgoCD syncs from the branch `apps/root.yaml` tracks. Force a
  re-read with the `argocd.argoproj.io/refresh=hard` annotation.
- **`kubectl kustomize` silently skips KSOPS**, so it does not check secrets. Use
  the standalone `kustomize build` above.
- **Render Helm charts** rather than reasoning about defaults; several bugs here
  only showed in rendered output.
- **ArgoCD is not self-managed**: `infra/argocd/values.yaml` is applied by hand
  with `helm upgrade` and a pinned chart version.
- **Secrets**: edit with `sops set`, which prints no plaintext. `age.key` is
  gitignored.
- **Images**: CI publishes `:vX.Y.Z` and `:latest` on `v*` tags only.
  A bump is a manifest edit and a commit (the sites' and some apps' CI commit it
  themselves), so the kustomizations are the deploy record and rollback is
  pointing an image back at an earlier digest.
- **Keycloak realm import is create-only**: an edit to `gtfs-realm.json` must also
  be made by hand on the running Keycloak.
- **Templates run inside comments** in Traefik's file provider and gomplate.
  Never write a template expression in a comment.
- **Gatus config** is `gtfs/gatus/config.yaml`. An endpoint alerts only with its
  own `alerts: - type: telegram`; `default-alert` is a template, not an opt-out.

## Conventions

- **Commits**: Conventional Commits, enforced by the `commit-msg` hook. Setup and
  release are in [CONTRIBUTING.md](CONTRIBUTING.md).
- **Cross-repo work**: sibling gtfs.zone repos live under the same parent
  directory and may be read and edited when a change spans repos.
- **Plans**: write plans to `CURRENT_PLAN.md` at the repo root as a
  checklist (`- [ ]`), ticked off as work lands. It is neither tracked nor
  gitignored: never stage or commit it.
