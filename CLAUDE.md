# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository deploys the **GTFS-RT** (General Transit Feed Specification –
Real Time) stack for `gtfs.zone` onto a single-node **k3s** cluster, managed
entirely by **ArgoCD** watching this repo (app-of-apps). There is no imperative
deploy step: you change YAML, commit, push, and ArgoCD reconciles.

The previous OpenTofu/Docker deployment was removed in the k3s migration; the
git history holds the full record. `tf/`, `tf-monitors/`, `nanomq/`, `traefik/`
and `dex/` no longer exist.

## Layout

Third-party components are upstream **Helm charts** referenced from ArgoCD
`Application`s; our own workloads are plain manifests assembled with **Kustomize**.
Secrets are **SOPS + age**, decrypted at render time by a **KSOPS** plugin
sidecar on the argocd-repo-server.

- `apps/`: ArgoCD `Application` manifests. `root.yaml` is the app-of-apps root
  (points ArgoCD at `apps/`); every other file is one `Application`. Adding a
  platform component = adding one file here. Infra charts use the multi-source
  pattern: upstream chart + `$values/infra/<comp>/values.yaml` from this repo.
- `infra/`: cluster platform pieces (Helm value overlays + a few raw CRs):
  `longhorn/` (storage), `traefik/` (edge, host :8443), `cert-manager/`
  (operator + Porkbun DNS-01 webhook values + `manifests/` ClusterIssuer &
  Certificate), `external-dns/` (Porkbun webhook provider), `cnpg/`
  (CloudNativePG operator), `argocd/` (ArgoCD's own Helm values + KSOPS sidecar,
  plus `manifests/` for its Certificate + IngressRoute), and `secrets/`
  (SOPS-encrypted Porkbun creds, one per consuming namespace).
- `gtfs/`: the application stack (Kustomize): Postgres (CNPG), Redis, Keycloak,
  oauth2-proxy, rt-api, celery, uptime-kuma, Traccar, vehicle-poser,
  hell-gate-bridge, IngressRoutes, and SOPS-encrypted `secrets/*.enc.yaml`.
- `sites/`: the three static sites (Kustomize, no secrets): `gtfs.zone`
  (landing-zone), `edit.gtfs.zone` (coloring-book), `viz.rt.gtfs.zone`
  (test-track). Each is an nginx image built by its own repo's CI and pushed to
  the Forgejo registry; that CI then runs `kustomize edit set image` here and
  commits, so `sites/kustomization.yaml` is the deploy record. Rollback = point
  the image back at an earlier digest. Their IngressRoutes deliberately live in
  the `gtfs` namespace, where the TLS Secrets are.
- `.sops.yaml`: age recipient + encryption rules. The private key (`age.key`)
  is gitignored.

Namespaces: `gtfs`, `sites`, `argocd`, `cert-manager`, `traefik`,
`external-dns`, `cnpg-system`, `longhorn-system`.

## Cluster access

**Run kubectl on the node over SSH.** The `KUBECONFIG` export is required: the
remote user's `~/.kube/config` is an empty stub. `/etc/rancher/k3s/k3s.yaml` is
mode 644, so no sudo.

```bash
ssh kcfam 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n argocd get pods'
```

An SSH tunnel also works, but it has proven flaky under load (it died mid-run
during a helm upgrade and hung the openapi fetch):

```bash
ssh -N -L 6443:127.0.0.1:6443 kcfam
```

`helm` is not in the node's default PATH; there is a copy at `~/bin/helm` on
`kcfam`, put there because running helm on the node beats running it through the
tunnel.

ArgoCD UI: `https://argocd.gtfs.zone`, via **Log in via Keycloak** (the `argocd`
client in the `gtfs` realm). Access requires membership in the `argocd-admins`
Keycloak group; `policy.default` is empty, so a realm account without it can
sign in and see nothing. CLI: `argocd login argocd.gtfs.zone --sso`.

Keycloak admin console: `https://id.gtfs.zone/admin/gtfs/console`, with a normal
realm account (GitHub/Google/GitLab brokered) that is in the `keycloak-admins`
group; that group carries the `realm-management` `realm-admin` client role and
scopes to the `gtfs` realm only. The master-realm `admin`
(`KEYCLOAK_ADMIN_PASSWORD` in `gtfs-app-secrets`) stays break-glass.

The local `admin` account is kept enabled as **break-glass**, because Keycloak
runs in the `gtfs` namespace against the CNPG cluster ArgoCD itself deploys:
if the `gtfs` app is broken, SSO is down too.

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

**ArgoCD is not self-managed.** `infra/argocd/values.yaml` (SSO, RBAC, the KSOPS
sidecar) is applied by hand, and always with a pinned chart version so the
change does not also bump ArgoCD:

```bash
helm upgrade argocd argo/argo-cd -n argocd --version 10.1.4 -f infra/argocd/values.yaml
```

## Working on this repo

**Cross-repo work is allowed.** The sibling `gtfs.zone` repos (see *Related
repositories* below) live under the same parent directory; read and edit them
directly when a change spans repos. There is no "this repo only" restriction.

**There are no `apply` commands.** Commit and push to the branch ArgoCD tracks
(`apps/root.yaml` → `targetRevision`); ArgoCD syncs automatically. To force a
re-read: `kubectl annotate app <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite`.

**Before every commit, render the tree the way ArgoCD's KSOPS CMP does:**

```bash
PATH="$HOME/.local/bin:$PATH" SOPS_AGE_KEY_FILE=$PWD/age.key \
  kustomize build --enable-alpha-plugins --enable-exec gtfs
```

Standalone `kustomize` is not installed on the dev machine; install it for the
above. `kubectl kustomize --enable-alpha-plugins gtfs` renders everything else
but silently skips the KSOPS generator, so it does not check secrets.

**Validate Helm value changes by rendering the real chart** rather than reasoning
about defaults; several chart-default bugs in this stack were only visible in
the rendered output:

```bash
helm template <release> <repo>/<chart> --version <v> -n <ns> -f infra/<comp>/values.yaml
```

**Editing a secret:** use `sops set` (it does not print plaintext). You rarely
need to decrypt: SOPS leaves key names readable.

**Images:** CI publishes `:latest` + `:<short-sha>` only; there is **no `:main`
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
     Traefik (Helm), websecure entrypoint on host :8443 via ServiceLB
       └─ IngressRoute: rt · manage.rt · id · auth · uptime · status · traccar
          (+ argocd, in the argocd namespace)
     cert-manager (Porkbun DNS-01) · external-dns · Longhorn · CNPG · ArgoCD
```

TLS for `*.gtfs.zone` is owned end to end by cert-manager in the cluster; the
edge only passes bytes through. The bare apex `gtfs.zone` is deliberately **not**
passed through: it stays on home-docker's static-sites container.

### Ingest data flow

```
 driver phone (Traccar Client)
   └─ HTTPS traccar.gtfs.zone/osmand ──▶ Traccar :5055
 web/REST/QR provisioning
   └─ HTTPS traccar.gtfs.zone       ──▶ Traccar :8082 (Keycloak OIDC login)
                                            │ forward.type=json
                                            ▼
                                 vehicle-poser :8080 /forward
                                 (resolve trip → Redis DB1, 60s TTL)
                                            │
 Amtrak feed  ── hell-gate-bridge (amtrak)  ─┤ POST /ingest/* (bearer token)
 Columbia Cty ── hell-gate-bridge (buswhere)─┤ (positions *and* trip updates)
                                            │
                                            ├──▶ vehicle:{tracker}:* (DB1, 60s)
                                            │            │ sweep every 5s
                                            │      trip-updogger
                                            │      (project fix on schedule)
                                            │            ▼
                                            ├──▶ trip_update:{trip} (DB1, 300s)
                                            ▼
                                     cafe-car (rt-api)
                                     GTFS-RT at rt.gtfs.zone
```

**MQTT** is permanently retired: NanoMQ and OwnTracks are gone and are not
coming back. Positions arrive over HTTP only; Redis is still the seam.

`trip-updogger` is **not** retired; it came back in a different shape. It is now
a Redis→Redis worker with no broker: it sweeps `vehicle:*`, loads the trip's
scheduled `stop_times` from Postgres, and writes `trip_update:*`. It is what turns
a raw position into a *delay*, so without it a Traccar-sourced feed serves
positions and an **empty `trip_updates.pb`**.

### Service map

| Layer | What runs |
|---|---|
| Edge | Traefik (Helm), `websecure` on host :8443; `IngressRoute`/`Middleware` CRDs |
| TLS / DNS | cert-manager + Porkbun DNS-01 webhook; external-dns (Porkbun webhook) |
| Storage | Longhorn (default StorageClass, 1 replica) |
| Database | CloudNativePG `Cluster` `postgres` → `rt_api`, `keycloak`, `traccar` databases |
| Cache | Redis (DB 0 oauth2-proxy · 1 rt-api+poser · 3 celery broker · 4 celery result) |
| Auth | Keycloak (OIDC, `id.gtfs.zone`, brokers GitHub/Google/GitLab) + oauth2-proxy (ForwardAuth via two Middlewares). Traccar is a separate Keycloak client with its own login, gated on the `gtfs-admins` group, see `gtfs/keycloak/CUTOVER.md` |
| Application | rt-api (`gtfs-api` :8000 public, `gtfs-manager` :8001 protected), celery worker + beat |
| Ingest | Traccar, vehicle-poser, trip-updogger, hell-gate-bridge ×2 |
| Monitoring | Uptime Kuma |

### Related repositories

- **[cafe-car](https://git.kcfam.us/gtfs.zone/cafe-car)**: GTFS-RT API + manager
- **[vehicle-poser](https://git.kcfam.us/gtfs.zone/vehicle-poser)**: HTTP forward receiver (Traccar → Redis)
- **[trip-updogger](https://git.kcfam.us/gtfs.zone/trip-updogger)**: schedule-delay worker (positions → trip updates)
- **[hell-gate-bridge](https://git.kcfam.us/gtfs.zone/hell-gate-bridge)**: Amtrak + Columbia County pollers
- **[schedule-foamer](https://git.kcfam.us/gtfs.zone/schedule-foamer)**: Celery worker/beat
- **[railroad-club](https://git.kcfam.us/gtfs.zone/railroad-club)**: shared SQLAlchemy models + Alembic migrations
- **[music-student](https://git.kcfam.us/gtfs.zone/music-student)**: Docker Compose stack for local dev
- **[landing-zone](https://git.kcfam.us/gtfs.zone/landing-zone)**: static homepage at the apex

## Patterns worth knowing

**Database migrations** run as an ArgoCD **PreSync hook Job**
(`gtfs/rt-api-migrate.yaml`) using the `railroad-club` migrations, so Alembic
completes before any rollout. If a hook Job wedges, ArgoCD's `hook-finalizer`
deadlocks against its own stuck operation; clear the operation
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
original 401 status code**: a 401 whose body is oauth2-proxy's Sign In page is
correct behaviour, not a failure.

**Adding a hostname:** add an `IngressRoute` with the
`external-dns.alpha.kubernetes.io/target: "73.4.232.254"` annotation; external-dns
creates the Porkbun record from it. Remember a DNS wildcard matches exactly **one**
label: `*.gtfs.zone` does not cover `anything.rt.gtfs.zone`, which is why
`gtfs-zone-tls` also carries `*.rt.gtfs.zone`.

**Traccar config:** `CONFIG_USE_ENVIRONMENT_VARIABLES=true` makes env override
`traccar.xml`. The env name is **not** simply the key uppercased: Traccar inserts
an underscore before each capital first, so `openid.clientSecret` is
`OPENID_CLIENT_SECRET`. Getting this wrong is silent: the pod stays healthy and
only `/api/server` breaks.

## Traps that have already bitten

Each of these cost real debugging time.

- **Template calls inside comments.** Both gomplate (Dex config) and Traefik's
  file provider template the *entire file, comments included*. A template
  expression written in a comment to document syntax gets executed, and the whole
  file is discarded, silently, in Traefik's case.
- **Keycloak's `pkce.code.challenge.method` is a requirement, not an offer.**
  Setting it on a client makes Keycloak demand a `code_challenge` on *every*
  flow of that client. argocd-server's browser login is a confidential-client
  code flow that sends none, so the whole sign-in failed with `invalid_request:
  Missing parameter: code_challenge_method`. The argocd client does not set it.
- **Keycloak realm import is create-only.** `gtfs/keycloak/gtfs-realm.json` is
  applied when the realm does not exist and never again, so editing it changes
  nothing on the running Keycloak. Every group, client scope and client change
  has to be made a second time by hand (admin console, or `kcadm.sh` inside the
  pod) and the file kept in sync for the next fresh realm. Nothing detects the
  drift.
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

- **Two producers share the `trip_update:*` namespace,** and they divide it by a
  `source` stamp, not by key prefix. `trip-updogger` stamps every record it writes
  `source: trip-updogger` and refuses to touch a key that lacks that stamp, so
  hell-gate-bridge's richer per-stop predictions always win and trip-updogger only
  fills the gaps. cafe-car's `/ingest/trip-update` writes **no** `source` field,
  which is what makes this work; if a future producer ever starts writing that
  field, it will silently start losing its records to the sweeper.
- **`compute_delay` has no notion of a trip that hasn't started.** For a trip whose
  first stop is still hours away it projects the parked vehicle onto a later stop
  and reports a large bogus "early" delay (observed: −11700s on an Amtrak trip 3h
  before departure). Only visible on trips hell-gate-bridge did not itself predict,
  since those keys are deferred to. Fix belongs in `trip-updogger`'s `trip_math.py`.
- The `columbia-county` poller crashes every cycle on a `"departed"` string in
  buswhere's `stop_eta` (app bug; written up in `hell-gate-bridge`'s
  `BUSWHERE_DEPARTED_BUG.md`). Amtrak is unaffected.
- Uptime Kuma's public status page must be created in its UI: `status.gtfs.zone/`
  redirects to the private `/dashboard` until one exists. The old `tf-monitors/`
  root that configured this via API was deleted and not replaced.
- `infra-longhorn`'s CRDs and `gtfs`'s `Cluster/postgres` no longer show spurious
  OutOfSync, see `ignoreDifferences` in `apps/infra-longhorn.yaml` and
  `apps/gtfs.yaml`. Both the Longhorn CRD conversion webhook (self-injected
  `caBundle`) and CNPG's own mutating admission webhook (defaults ~18 `Cluster`
  spec fields, plus role defaults) write fields at persist time that are never in
  the applied manifest; with SSA, ArgoCD attributes those to its own field
  manager, so only explicit `jsonPointers`/`jqPathExpressions` fix it; this is
  *not* transient and does not resolve itself. If either Application goes
  OutOfSync again on a *new* field after a chart/operator upgrade, diff
  `helm template`/`kubectl get -o yaml` output against the live object to find
  the newly-defaulted path and add it to the same list.
- **Traccar scopes device visibility per user, and being an administrator does
  not change that.** `openid.adminGroup` grants the admin console (Users,
  Settings) but the device list is still driven by the `tc_user_device` join
  table, so a fresh OIDC admin logs in and sees zero devices until each one is
  shared with `POST /api/permissions`. Confirmed the hard way: all 7 devices were
  linked only to `admin@gtfs.zone` (cafe-car's service account), and the first
  real OIDC admin login saw none of them. The table is many-to-many, so granting
  a second user does not take access away from the first.

  Mitigated, not closed: every device now belongs to the Traccar group **All
  Vehicles** (`settings.traccar_device_group`, set by cafe-car's
  `ensure_device`), so a new admin is one share of that group rather than one
  share per device. That share is still manual, in the UI or
  `POST /api/permissions {"userId": N, "groupId": G}`. A device created outside
  cafe-car, by hand in the Traccar UI, gets no group and stays invisible.
- No backups yet. CNPG scheduled backups + Longhorn snapshots are the obvious
  next step now that Traccar keeps durable position history.
