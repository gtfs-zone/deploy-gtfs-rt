# Handoff prompt — finish the k3s migration (Phases 8–10)

Copy everything below the line into a fresh agent session started in
`/home/maxtkc/Documents/deploy-gtfs-rt`.

---

You are finishing a migration of the `gtfs.zone` stack from OpenTofu-managed
Docker containers to a GitOps-managed k3s + ArgoCD deployment. Read
**`CURRENT_PLAN.md`** first — it is current as of commit `91d84a0` and is the
source of truth. Phases 0–7 are done; **Phases 8, 9 and 10 remain**.

Work on branch `k3s-init`. There is one uncommitted-to-remote commit: `91d84a0`
(docs) may still need pushing — check `git log origin/k3s-init..k3s-init`.

## Before anything: cluster access

The kubeconfig points at `127.0.0.1:6443`, so kubectl only works while an SSH
tunnel is up. If `kubectl get nodes` fails, ask the user to run:

```
ssh -N -L 6443:127.0.0.1:6443 kcfam
```

Do not try to start it yourself in the background — ask, and wait.

## Phase 8, step 0 — unblock Longhorn (do this first)

Nothing else can start until this is fixed. `infra-longhorn` is
**OutOfSync/Missing**, so the only StorageClass is `local-path`, so the CNPG
`postgres-1-initdb` Job and the Redis pod have been `Pending` for over a week,
so the whole `gtfs` app is Degraded.

What is already established — do not re-derive it:
- `iscsid` is **active** on the node and `iscsiadm` is present.
- `helm template longhorn/longhorn --version 1.8.1 -f infra/longhorn/values.yaml`
  renders, and `kubectl apply --server-side --dry-run=server` on the result
  applies cleanly. So the manifests are not the problem.
- The sync failed at revision `01836fa` and ArgoCD logs
  `"Skipping auto-sync: failed previous sync attempt … and will not retry"`.
  That is why it never recovered on its own: ArgoCD will not retry *the same*
  revision. The original error message has rotated out of the controller logs.

Since `3f1cc67`/`91d84a0` are new revisions, auto-sync should retry by itself.
Check whether it has. If it is still stuck, trigger one sync manually and then
**read the actual per-resource failure** before changing any manifest — do not
guess at a fix. `nfs-common` is missing on the node but is only needed for RWX
volumes, which this stack does not use.

Once Longhorn is Healthy, confirm the `longhorn` StorageClass is default, the
PVCs bind, CNPG bootstraps `rt_api`/`dex`/`traccar`, and the `gtfs-migrate`
PreSync Job runs Alembic successfully.

## Phase 8, step 1 — author the ArgoCD IngressRoute

`gtfs/ingressroutes.yaml` covers rt, manage.rt, dex, auth, uptime, status and
traccar — but **not** ArgoCD, which lives in the `argocd` namespace. Add one for
host `argocd.gtfs.zone` → the argocd-server Service, TLS from `gtfs-zone-tls`,
with the same `external-dns.alpha.kubernetes.io/target: 73.4.232.254`
annotation the others carry. Note `server.insecure: true` is already set in
`infra/argocd/values.yaml`. The `gtfs-zone-tls` Secret is issued into the `gtfs`
namespace, so this needs either a copy in `argocd` or a second Certificate —
decide and say which.

## Phase 8, steps 2–8 — bring-up

Follow the numbered list in `CURRENT_PLAN.md` § Phase 8. Highlights:

- Bootstrap the Traccar admin with **exactly** the `TRACCAR_ADMIN_EMAIL` /
  `TRACCAR_ADMIN_PASSWORD` values already in `gtfs-app-secrets` — rt-api uses
  those same credentials for device auto-provisioning, so a different password
  silently breaks cafe-car→Traccar. The first `POST /api/users` on an empty
  `tc_users` becomes administrator (verified).
- `PUT /api/server {"registration": true}` so Dex logins auto-provision managers.
- The two pollers' `INGEST_VEHICLE_ID`s (`amtrak-live`, `columbia-county`) must
  equal provisioned `Tracker.id`s. A mismatch is **silent** — no positions, no
  error. Likewise an unset `INGEST_API_TOKEN` sends a literal `Bearer None`, so
  check the pollers log 2xx from `/ingest/position`, not 401.

The edge cutover (`home-docker` `tofu apply`) is a **user action** — the
passthrough config is already written at
`home-docker/traefik/dynamic/gtfs-zone-passthrough.yml` but the dynamic dir is
baked into a locally-built Traefik image, so it needs a rebuild. Ask before
assuming it has happened; until it does, nothing on `*.gtfs.zone` reaches the
cluster from outside and you must verify in-cluster (port-forward / exec).

## Phases 9 and 10

Only after Phase 8 verifies end to end. Phase 9 destroys the old Docker stack
(`tofu destroy`, volumes have `prevent_destroy` blocks to remove first) and
deletes `tf/ tf-monitors/ nanomq/ traefik/ dex/`, then rewrites `CLAUDE.md` and
`README.md` for the k8s layout. **Confirm with the user before `tofu destroy`** —
it is irreversible and abandons the old data on purpose.

Phase 10 opens one PR `k3s-init` → `main`, then flips `apps/root.yaml`
`targetRevision` to `main` and applies it by hand once. `gh` only knows
github.com and `tea` is not installed; `forgejo-mcp` is at `~/go/bin/forgejo-mcp`
and needs `FORGEJO_ACCESS_TOKEN`, otherwise the user opens the PR in the web UI.

## Working rules

- **Verify, don't assume.** The previous session caught four real bugs by
  actually running things (a wrong module path, a missing celery `--schedule`, an
  8-day external-dns crash loop, a stale image pin) and resolved both of the
  plan's open risks by booting `traccar/traccar:6.14.5` in Docker rather than
  reasoning about it. Docker is available locally for exactly this.
- Before every commit, render the tree the same way ArgoCD's KSOPS CMP does:
  ```
  PATH="$HOME/.local/bin:$PATH" SOPS_AGE_KEY_FILE=$PWD/age.key \
    kustomize build --enable-alpha-plugins --enable-exec gtfs
  ```
- CI publishes `:latest` + `:<short-sha>` only — there is **no `:main` tag**.
  Bumping an image is a manifest edit plus a commit.
- Editing a secret: use `sops set` (it does not print plaintext). Decrypting a
  secret to stdout is blocked by the permission classifier, and you do not need
  to — SOPS leaves the key names readable.
- Pushing may be blocked by the classifier. If it is, stop and give the user the
  exact command rather than working around it.
- Downtime is explicitly **not** a concern and no data is being preserved. Do not
  invent migration or dual-run steps.
