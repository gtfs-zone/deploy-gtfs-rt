# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository deploys the **GTFS-RT** (General Transit Feed Specification –
Real Time) stack for `gtfs.zone` onto a single-node **k3s** cluster, managed
entirely by **ArgoCD** watching this repo (app-of-apps). There is no imperative
deploy step: you change YAML, commit, push, and ArgoCD reconciles.

The previous OpenTofu/Docker deployment was removed in the k3s migration — see
`CURRENT_PLAN.md` for the full history and the defects found along the way.
`tf/`, `tf-monitors/`, `nanomq/`, `traefik/` and `dex/` no longer exist.

## Layout

Third-party components are upstream **Helm charts** referenced from ArgoCD
`Application`s; our own workloads are plain manifests assembled with **Kustomize**.
Secrets are **SOPS + age**, decrypted at render time by a **KSOPS** plugin
sidecar on the argocd-repo-server.

- `apps/` — ArgoCD `Application` manifests. `root.yaml` is the app-of-apps root
  (points ArgoCD at `apps/`); every other file is one `Application`. Adding a
  platform component = adding one file here. Infra charts use the multi-source
  pattern: upstream chart + `$values/infra/<comp>/values.yaml` from this repo.
- `infra/` — cluster platform pieces (Helm value overlays + a few raw CRs):
  `longhorn/` (storage), `traefik/` (edge, host :8443), `cert-manager/`
  (operator + Porkbun DNS-01 webhook values + `manifests/` ClusterIssuer &
  Certificate), `external-dns/` (Porkbun webhook provider), `cnpg/`
  (CloudNativePG operator), `argocd/` (ArgoCD's own Helm values + KSOPS sidecar,
  plus `manifests/` for its Certificate + IngressRoute), and `secrets/`
  (SOPS-encrypted Porkbun creds, one per consuming namespace).
- `gtfs/` — the application stack (Kustomize): Postgres (CNPG), Redis, Dex,
  oauth2-proxy, rt-api, celery, uptime-kuma, Traccar, vehicle-poser,
  hell-gate-bridge, IngressRoutes, and SOPS-encrypted `secrets/*.enc.yaml`.
- `.sops.yaml` — age recipient + encryption rules. The private key (`age.key`)
  is gitignored.

Namespaces: `gtfs`, `argocd`, `cert-manager`, `traefik`, `external-dns`,
`cnpg-system`, `longhorn-system`.

## Cluster access

The kubeconfig points at `127.0.0.1:6443`, so **kubectl only works while an SSH
tunnel is up**:

```bash
ssh -N -L 6443:127.0.0.1:6443 kcfam
```

ArgoCD UI: `https://argocd.gtfs.zone`. Admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Working on this repo

**There are no `apply` commands.** Commit and push to the branch ArgoCD tracks
(`apps/root.yaml` → `targetRevision`); ArgoCD syncs automatically. To force a
re-read: `kubectl annotate app <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite`.

**Before every commit, render the tree the way ArgoCD's KSOPS CMP does:**

```bash
PATH="$HOME/.local/bin:$PATH" SOPS_AGE_KEY_FILE=$PWD/age.key \
  kustomize build --enable-alpha-plugins --enable-exec gtfs
```

**Validate Helm value changes by rendering the real chart** rather than reasoning
about defaults — several chart-default bugs in this stack were only visible in
the rendered output:

```bash
helm template <release> <repo>/<chart> --version <v> -n <ns> -f infra/<comp>/values.yaml
```

**Editing a secret:** use `sops set` (it does not print plaintext). You rarely
need to decrypt — SOPS leaves key names readable.

**Images:** CI publishes `:latest` + `:<short-sha>` only — there is **no `:main`
tag**. Bumping an image is a manifest edit plus a commit. The `git.kcfam.us`
packages are public (anonymously pullable), so no `imagePullSecrets` are used.

## Architecture

```
Internet :80/:443
   └─ home-docker Traefik (Docker, still owns 80/443)
        ├─ *.kcfam.us + gtfs.zone apex → terminated locally
        └─ *.gtfs.zone → TCP SNI passthrough → 172.18.0.1:8443
                                                   │
   k3s single node ─────────────────────────────────┘
     Traefik (Helm) — websecure entrypoint on host :8443 via ServiceLB
       └─ IngressRoute: rt · manage.rt · dex · auth · uptime · status · traccar
          (+ argocd, in the argocd namespace)
     cert-manager (Porkbun DNS-01) · external-dns · Longhorn · CNPG · ArgoCD
```

TLS for `*.gtfs.zone` is owned end to end by cert-manager in the cluster; the
edge only passes bytes through. The bare apex `gtfs.zone` is deliberately **not**
passed through — it stays on home-docker's static-sites container.

### Ingest data flow

```
 driver phone (Traccar Client)
   └─ HTTPS traccar.gtfs.zone/osmand ──▶ Traccar :5055
 web/REST/QR provisioning
   └─ HTTPS traccar.gtfs.zone       ──▶ Traccar :8082 (Dex OIDC login)
                                            │ forward.type=json
                                            ▼
                                 vehicle-poser :8080 /forward
                                 (resolve trip → Redis DB1, 60s TTL)
                                            │
 Amtrak feed  ── hell-gate-bridge (amtrak)  ─┤ POST /ingest/* (bearer token)
 Columbia Cty ── hell-gate-bridge (buswhere)─┤
                                            ▼
                                     cafe-car (rt-api)
                                     GTFS-RT at rt.gtfs.zone
```

MQTT is **permanently retired** — NanoMQ, OwnTracks and `trip-updogger` are gone
and are not coming back. Positions arrive over HTTP only; Redis is still the seam.

### Service map

| Layer | What runs |
|---|---|
| Edge | Traefik (Helm), `websecure` on host :8443; `IngressRoute`/`Middleware` CRDs |
| TLS / DNS | cert-manager + Porkbun DNS-01 webhook; external-dns (Porkbun webhook) |
| Storage | Longhorn (default StorageClass, 1 replica) |
| Database | CloudNativePG `Cluster` `postgres` → `rt_api`, `dex`, `traccar` databases |
| Cache | Redis (DB 0 oauth2-proxy · 1 rt-api+poser · 3 celery broker · 4 celery result) |
| Auth | Dex (OIDC) + oauth2-proxy (ForwardAuth via two Middlewares) |
| Application | rt-api (`gtfs-api` :8000 public, `gtfs-manager` :8001 protected), celery worker + beat |
| Ingest | Traccar, vehicle-poser, hell-gate-bridge ×2 |
| Monitoring | Uptime Kuma |

### Related repositories

- **[cafe-car](https://git.kcfam.us/gtfs.zone/cafe-car)** — GTFS-RT API + manager
- **[vehicle-poser](https://git.kcfam.us/gtfs.zone/vehicle-poser)** — HTTP forward receiver (Traccar → Redis)
- **[hell-gate-bridge](https://git.kcfam.us/gtfs.zone/hell-gate-bridge)** — Amtrak + Columbia County pollers
- **[schedule-foamer](https://git.kcfam.us/gtfs.zone/schedule-foamer)** — Celery worker/beat
- **[railroad-club](https://git.kcfam.us/gtfs.zone/railroad-club)** — shared SQLAlchemy models + Alembic migrations
- **[music-student](https://git.kcfam.us/gtfs.zone/music-student)** — Docker Compose stack for local dev
- **[landing-zone](https://git.kcfam.us/gtfs.zone/landing-zone)** — static homepage at the apex

## Patterns worth knowing

**Database migrations** run as an ArgoCD **PreSync hook Job**
(`gtfs/rt-api-migrate.yaml`) using the `railroad-club` migrations, so Alembic
completes before any rollout. If a hook Job wedges, ArgoCD's `hook-finalizer`
deadlocks against its own stuck operation — clear the operation
(`kubectl patch app <n> -n argocd --type merge -p '{"operation":null}'`)
*before* removing the finalizer.

**Adding auth to a service:** attach both Middlewares to its IngressRoute route,
in this order:

```yaml
middlewares:
  - name: oauth2-errors
  - name: oauth2-proxy
```

Note Traefik's `errors` middleware serves the sign-in page **while preserving the
original 401 status code** — a 401 whose body is oauth2-proxy's Sign In page is
correct behaviour, not a failure.

**Adding a hostname:** add an `IngressRoute` with the
`external-dns.alpha.kubernetes.io/target: "73.4.232.254"` annotation — external-dns
creates the Porkbun record from it. Remember a DNS wildcard matches exactly **one**
label: `*.gtfs.zone` does not cover `anything.rt.gtfs.zone`, which is why
`gtfs-zone-tls` also carries `*.rt.gtfs.zone`.

**Traccar config:** `CONFIG_USE_ENVIRONMENT_VARIABLES=true` makes env override
`traccar.xml`. The env name is **not** simply the key uppercased — Traccar inserts
an underscore before each capital first, so `openid.clientSecret` is
`OPENID_CLIENT_SECRET`. Getting this wrong is silent: the pod stays healthy and
only `/api/server` breaks.

## Traps that have already bitten

Each of these cost real debugging time. See `CURRENT_PLAN.md` § Phase 8 for detail.

- **Template calls inside comments.** Both gomplate (Dex config) and Traefik's
  file provider template the *entire file, comments included*. A template
  expression written in a comment to document syntax gets executed, and the whole
  file is discarded — silently, in Traefik's case.
- **Helm `pre-upgrade` hooks under ArgoCD** become PreSync hooks and run before
  the chart's own ServiceAccount exists. Longhorn ships one; it is disabled via
  `preUpgradeChecker.jobEnabled: false`.
- **Helm release names change ServiceAccount names.** The cert-manager Porkbun
  webhook must be told `certManager.serviceAccountName: infra-cert-manager`.
- **DNS-01 apex/wildcard collision.** `gtfs.zone` and `*.gtfs.zone` validate at
  the same TXT name and the Porkbun webhook replaces rather than appends, so
  requesting both on one Certificate deadlocks issuance.
- **Longhorn volumes mount root-owned and contain a `lost+found`,** which makes
  some images skip their own permission fixup. Use `fsGroup`.
- **Chart-default port mismatches.** The external-dns chart hardcodes the webhook
  sidecar's containerPort/probes to 8080 while the Porkbun webhook binary
  defaults to :8888. Always render the chart.
- **Host inotify limits.** k3s + Longhorn + containerd share root's
  `fs.inotify.max_user_instances`; at the default 128 they exhausted it and
  home-docker's Traefik could not start its file provider at all. Raised to 1024
  in `/etc/sysctl.d/99-inotify.conf`.

## Known gaps

- The `columbia-county` poller crashes every cycle on a `"departed"` string in
  buswhere's `stop_eta` (app bug; written up in `hell-gate-bridge`'s
  `BUSWHERE_DEPARTED_BUG.md`). Amtrak is unaffected.
- Uptime Kuma's public status page must be created in its UI — `status.gtfs.zone/`
  redirects to the private `/dashboard` until one exists. The old `tf-monitors/`
  root that configured this via API was deleted and not replaced.
- `infra-longhorn`'s CRDs and `gtfs`'s `Cluster/postgres` no longer show spurious
  OutOfSync — see `ignoreDifferences` in `apps/infra-longhorn.yaml` and
  `apps/gtfs.yaml`. Both the Longhorn CRD conversion webhook (self-injected
  `caBundle`) and CNPG's own mutating admission webhook (defaults ~18 `Cluster`
  spec fields, plus role defaults) write fields at persist time that are never in
  the applied manifest; with SSA, ArgoCD attributes those to its own field
  manager, so only explicit `jsonPointers`/`jqPathExpressions` fix it — this is
  *not* transient and does not resolve itself. If either Application goes
  OutOfSync again on a *new* field after a chart/operator upgrade, diff
  `helm template`/`kubectl get -o yaml` output against the live object to find
  the newly-defaulted path and add it to the same list.
- Traccar scopes device visibility per user, so an OIDC-provisioned manager sees
  no devices until they are shared (`POST /api/permissions`).
- No backups yet. CNPG scheduled backups + Longhorn snapshots are the obvious
  next step now that Traccar keeps durable position history.
