# Plan: Migrate deploy-gtfs-rt to k3s + ArgoCD

Migrate the `gtfs.zone` stack from OpenTofu-managed Docker containers to a
GitOps-managed Kubernetes deployment on a single-node **k3s** cluster, driven by
**ArgoCD**. This is a pilot for eventually moving the whole server (including the
`home-docker` / `kcfam.us` stack) to k3s, so we set up the "industry standard"
patterns now even though the project is small.

**Branch:** all of this work lives on the single branch **`k3s-init`**, cut from
`main`, merged back as one PR. Nothing else is in flight.

> **Revision 2026-07-31.** The application architecture changed underneath this
> plan while Phases 0–6 were being built: `music-student` completed its
> OwnTracks→**Traccar** migration (its Phases 1–7). The k3s target must now
> deploy the *new* ingest stack — Traccar, a resurrected HTTP-mode
> `vehicle-poser`, and two `hell-gate-bridge` pollers — not the "realtime ingest
> is dropped, restore it later" shape the original plan assumed. Phases 5a and
> 6a below capture that delta. See `TRACCAR_MIGRATION_FEASIBILITY.md` for the
> original study and `music-student`'s `docs/traccar.md` for the shipped design.

---

## Locked decisions

| Decision | Choice | Why |
|---|---|---|
| **Scope** | Migrate `gtfs.zone` only; `home-docker` stays on Docker for now | Data gravity — gtfs data is disposable; home-docker holds irreplaceable Nextcloud/Immich data + Forgejo (which serves our images). Pilot on the cheap stack. |
| **Ingest** | **Traccar + HTTP**, no MQTT anywhere | NanoMQ, OwnTracks and `trip-updogger` are permanently retired (done upstream in `music-student` Phase 7). Positions arrive over HTTP only; Redis is still the seam. |
| **Uptime / data** | **Neither is a goal.** No dual-run, no volume migration, no cutover choreography | Explicit: we care only that the destination is clean. Destroy the old stack, stand the new one up, re-provision from scratch. Any "keep it running during transition" language elsewhere is obsolete. |
| **Repo layout** | Top-level `apps/`, `infra/`, `gtfs/`; **delete `tf/`, `nanomq/`, `traefik/`, `dex/` on this branch** | Manifests replace Terraform in the same repo, in the same PR. No transition period. |
| **Secrets** | **SOPS + age**, decrypted in ArgoCD via **KSOPS** (kustomize plugin) | Portable GitOps secret pattern; secrets are normal YAML you can diff/rotate. |
| **Edge (80/443)** | `home-docker` Traefik stays the edge; **SNI-passthrough** `*.gtfs.zone` → k3s Traefik on host port 8443 | Least disruptive; k3s fully owns gtfs.zone TLS via cert-manager. All gtfs traffic — including Traccar phone reports — is plain HTTPS by SNI, so one passthrough rule covers everything. |
| **DNS** | **external-dns** (Porkbun webhook) from day one | Retires `dns.tf`; records come from IngressRoute annotations. |
| **Storage** | **Longhorn** (not local-path) | Chosen for a future multi-node cluster; replicated volumes + snapshots. |
| **Postgres** | **CloudNativePG** operator | Declarative users/dbs, backups, failover-ready. Hosts the `rt_api`, `dex` **and `traccar`** databases. |
| **Custom images** | Drop locally-built `traefik`/`dex` images → upstream images + mounted config | Removes a build/push pipeline; config-as-ConfigMap is k8s-native. |

---

## Target architecture

```
                          Internet  (one public IP = server_ip)
                               │  :80 / :443
                               ▼
                 ┌───────────────────────────────┐
                 │  home-docker Traefik (Docker)  │  ← unchanged, still owns 80/443
                 │  *.kcfam.us  → terminate here  │
                 │  *.gtfs.zone → TCP passthrough │──┐  (HostSNIRegexp, tls.passthrough)
                 └───────────────────────────────┘  │
                                                     ▼  host:8443 (k3s ServiceLB)
      ┌────────────────────────────────────────────────────────────────┐
      │  k3s single node                                                │
      │  Traefik (Helm) ── websecure entrypoint (:8443)                 │
      │    └─ IngressRoute  rt / manage.rt / dex / auth / uptime /      │
      │                     status / argocd / traccar                   │
      │  cert-manager (Porkbun DNS-01) · external-dns · Longhorn        │
      │  ArgoCD  ── watches this repo (app-of-apps)                     │
      │                                                                 │
      │  gtfs namespace:                                                │
      │    CNPG Postgres (rt_api · dex · traccar dbs) · Redis           │
      │    Dex · oauth2-proxy · rt-api (api + manager)                  │
      │    celery worker/beat · uptime-kuma                             │
      │    Traccar · vehicle-poser · hell-gate-bridge ×2                │
      └────────────────────────────────────────────────────────────────┘
```

### Ingest data flow (the part that changed)

```
 driver phone (Traccar Client)
   └─ HTTPS  traccar.gtfs.zone/osmand ──▶ Traccar :5055
 web/REST/QR provisioning
   └─ HTTPS  traccar.gtfs.zone       ──▶ Traccar :8082 ──┐ (Dex OIDC login)
                                                          │ forward.type=json
                                                          ▼
                              vehicle-poser :8080 /forward
                                (resolve_tracker_trip → Redis DB1, 60s TTL)
                                                          │
 Amtrak feed    ── hell-gate-bridge (SOURCE=amtrak)   ────┤ POST /ingest/* (bearer)
 Columbia Cty   ── hell-gate-bridge (SOURCE=buswhere) ────┤
                                                          ▼
                                                   cafe-car (rt-api)
                                                   GTFS-RT at rt.gtfs.zone
```

**Traccar exposure — one hostname, path-split.** `traccar.gtfs.zone` serves the
web/REST console from `:8082`; `traccar.gtfs.zone/osmand` routes to `:5055` (the
phone-report protocol port) behind a `StripPrefix` middleware. The Traccar Client
takes a full URL from the QR code, so the path is ours to choose. This avoids a
second, confusable hostname. ⚠️ **Verify in Phase 7** that the osmand decoder is
happy after StripPrefix (it parses query params, not the path); if not, fall back
to a distinct host such as `gps.gtfs.zone`. The web console is **not** behind
oauth2-proxy — Traccar does its own Dex OIDC — and `/osmand` must stay
unauthenticated (phones authenticate by device `uniqueId` only).

---

## Repo structure (end state)

```
deploy-gtfs-rt/
├── apps/                      # ArgoCD Application manifests (app-of-apps root)
│   ├── root.yaml
│   ├── infra-*.yaml           # longhorn, traefik, cert-manager (×3), external-dns,
│   │                          #   cnpg, secrets
│   └── gtfs.yaml
├── infra/                     # cluster platform (Helm value overlays + raw CRs)
│   ├── longhorn/ traefik/ cert-manager/ external-dns/ cnpg/ argocd/ secrets/
├── gtfs/                      # the application stack (Kustomize)
│   ├── kustomization.yaml · namespace.yaml
│   ├── postgres-cluster.yaml · redis.yaml
│   ├── dex/ · oauth2-proxy.yaml
│   ├── rt-api.yaml · rt-api-migrate.yaml · celery.yaml · uptime-kuma.yaml
│   ├── traccar/               # Deployment + traccar.xml ConfigMap + Services + retention CronJob
│   ├── vehicle-poser.yaml
│   ├── hell-gate-bridge.yaml  # two Deployments (amtrak, buswhere)
│   ├── ingressroutes.yaml
│   └── secrets/               # SOPS-encrypted Secrets (*.enc.yaml)
├── CLAUDE.md · README.md · CURRENT_PLAN.md
└── (tf/, tf-monitors/, nanomq/, traefik/, dex/ — DELETED in Phase 9)
```

**Conventions:** third-party components → upstream **Helm charts** via ArgoCD
multi-source `Application`s with in-repo values; our own workloads → plain
manifests assembled with **Kustomize**; one root `Application` (`apps/root.yaml`)
points at `apps/`, so adding a component = adding one file.

Namespaces: `gtfs`, `argocd`, `cert-manager`, `traefik`, `external-dns`,
`cnpg-system`, `longhorn-system`.

---

## Prerequisites & credentials

- SSH/sudo access to the server.
- **Porkbun API key + secret** — cert-manager DNS-01 **and** external-dns.
- **Registry pull credentials** for `git.kcfam.us` (Forgejo).
- OAuth connector secrets (GitHub/Google/GitLab) for Dex.
- Workstation tools: `kubectl`, `helm`, `kustomize`, `sops`, `age`, `argocd`
  (`sops`/`age`/`kustomize`/`ksops` are in `~/.local/bin` on this workstation).

⚠️ **Upstream app-repo prerequisite (blocking for Phase 6a).** Three of the four
application repos are on feature branches whose work is not yet on `main`, so no
`:main` image exists for them:

| Repo | Branch | Needs |
|---|---|---|
| `cafe-car` | `traccar-driver-provisioning` | merge to main → CI publishes image |
| `vehicle-poser` | `retire-driver-add-tracker` | merge to main → CI publishes image |
| `schedule-foamer` | `52-copier-apply` | merge to main → CI publishes image |
| `hell-gate-bridge` | `main` ✅ | confirm `.forgejo/workflows/build.yml` has published a tag |
| `railroad-club` | `main` ✅ | migrations already include Tracker/TrackerRule |

Each repo has `.forgejo/workflows/build.yml`; pin the resulting digests/tags in
the manifests. All `random_password` values are **regenerated fresh** — we are
not migrating data.

---

## Phased plan

### Phase 0 — Prep ✅ DONE
- age keypair for SOPS. Public recipient (in `.sops.yaml`):
  `age16mxws3n4s0my6k5jzy225shmpa36ag35v975xg4j6u7k3rjqn5dqvxw27c`.
  Private key `age.key` at repo root — **gitignored**; back it up out-of-band.
- Skeleton `apps/ infra/ gtfs/` created on branch `k3s-init`.
- ⚠️ **host-gateway IP must be re-confirmed on the server** in Phase 7:
  `docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'`
  on the home-docker host (the workstation's `192.168.222.1` is *not* it).

### Phase 1 — Install k3s ⚠️ MANUAL / sudo on the server
```bash
sudo apt-get install -y open-iscsi nfs-common     # Longhorn prereq
sudo systemctl enable --now iscsid
curl -sfL https://get.k3s.io | sudo sh -s - --disable traefik --write-kubeconfig-mode 644
```
Copy `/etc/rancher/k3s/k3s.yaml` off the server, fix `server:`. ServiceLB binds
whatever host port our Traefik `LoadBalancer` Service requests — **8443**, never
80/443.

### Phase 2 — Bootstrap ArgoCD ✅ DONE
- `argo/argo-cd` **10.1.4** (appVersion v3.4.5) in ns `argocd`; `server.insecure: true`.
- **KSOPS CMP sidecar** on argocd-repo-server (`infra/argocd/values.yaml`):
  `viaductoss/ksops:v4.3.3` initContainer + kustomize v5.3.0+ksops.v4.3.3; renders
  any tree containing `*.enc.yaml` via `kustomize build --enable-alpha-plugins --enable-exec`.
- `sops-age` Secret in `argocd` (from `age.key`, key `keys.txt`) — out-of-band root of trust.
- app-of-apps `apps/root.yaml` → HTTPS repo `https://git.kcfam.us/gtfs.zone/deploy-gtfs-rt.git`,
  path `apps/`, `targetRevision: k3s-init`, automated sync + prune + selfHeal. The repo is
  anonymously readable over HTTPS, so **no ArgoCD repo credential is needed**.
- Admin password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
- ⚠️ **TODO (Phase 10):** flip `targetRevision` `k3s-init` → `main` after merge.

### Phase 3 — Infra layer ✅ DONE (authored)
Every infra chart is an ArgoCD **multi-source** Application (upstream chart +
`$values/infra/<comp>/values.yaml` from this repo), `ServerSideApply=true`,
`CreateNamespace=true`, automated sync/prune/selfHeal, ordered by sync-wave:

- `infra-longhorn` (w0) — longhorn **1.8.1**, default SC, 1 replica.
- `infra-cnpg` (w0) — cloudnative-pg **0.28.0**, operator only.
- `infra-cert-manager` (w0) — **v1.17.4**, CRDs kept.
- `infra-traefik` (w1) — traefik **35.2.0**; only `websecure` exposed via
  LoadBalancer on host **8443**; `web`(:80) internal; CRD provider on.
- `infra-cert-manager-webhook-porkbun` (w1) — Talinx webhook **1.0.0**, group `porkbun.talinx.dev`.
- `infra-external-dns` (w1) — external-dns **1.16.1** + Porkbun webhook
  `ghcr.io/konnektr-io/external-dns-porkbun-webhook:v0.2.19`, source `traefik-proxy`,
  `domainFilters: [gtfs.zone]`, `policy: sync`, owner `gtfs-k3s`.
- `infra-cert-manager-config` (w2) — `ClusterIssuer letsencrypt-porkbun` +
  `Certificate gtfs-zone-tls` (`gtfs.zone` + `*.gtfs.zone` → Secret `gtfs-zone-tls` in ns `gtfs`).

⚠️ Deviation: cert-manager is **three** Applications (operator/webhook/config); the
`gtfs` namespace is created early by `infra-cert-manager-config` and adopted later.

### Phase 4 — Secrets (SOPS) ✅ DONE (authored + encrypted)
- Each secret tree is a KSOPS-rendered Kustomize dir (`kustomization.yaml` +
  `secret-generator.yaml` listing `*.enc.yaml`).
- `infra/secrets/` — `porkbun-secret` twice, once per consuming namespace
  (`cert-manager`: `PORKBUN_API_KEY`/`PORKBUN_SECRET_API_KEY`; `external-dns`:
  `API_KEY`/`API_SECRET`). Applied by `apps/infra-secrets.yaml` (w2).
- `gtfs/secrets/` — `gtfs-app-secrets` (session key, oauth2-proxy cookie secret,
  Dex↔oauth2-proxy client secret, six OAuth connector values),
  `registry-git-kcfam` (dockerconfigjson), and three CNPG basic-auth Secrets
  (`postgres-superuser`, `postgres-dex`, `postgres-rt-api`).
- ⚠️ Re-encrypting needs `PATH="$HOME/.local/bin:$PATH"` and `SOPS_AGE_KEY_FILE=<repo>/age.key`.

### Phase 5 — gtfs stateful layer ✅ DONE (authored)
- `gtfs/kustomization.yaml` root + `namespace.yaml`; ArgoCD Application
  `apps/gtfs.yaml` (wave 3), rendered by the ksops CMP.
- **CNPG `Cluster` `postgres`** — 1 instance, Longhorn 10Gi, image
  `ghcr.io/cloudnative-pg/postgresql:18.3`; `enableSuperuserAccess` +
  `superuserSecret`; `bootstrap.initdb` → `rt_api` role + db; `managed.roles: [dex]`
  + a `Database` CR → `dex` db.
- **Redis** — `redis:8.6-alpine` Deployment (`--appendonly yes`, `Recreate`) +
  Service :6379 + Longhorn PVC 2Gi. No auth (internal only). DBs 0/1/3/4 as before.

### Phase 5a — stateful layer delta for Traccar ⬜ TODO
1. Add a **`traccar` role + database** to the CNPG cluster, exactly like `dex`:
   a `postgres-traccar` basic-auth SOPS Secret, a `managed.roles` entry, and a
   `Database` CR (`owner: traccar`). Traccar owns and migrates its own schema.
2. Size the Postgres PVC for position history — `tc_positions` grows without
   bound (see the retention CronJob in Phase 6a). 10Gi is fine to start; note it.
3. Add the new secret values to `gtfs/secrets/gtfs-app-secrets.enc.yaml`:
   - `INGEST_API_TOKEN` — shared bearer for cafe-car `/ingest/*`; consumed by both
     hell-gate-bridge pollers.
   - `TRACCAR_ADMIN_EMAIL` / `TRACCAR_ADMIN_PASSWORD` — cafe-car's REST account for
     device auto-creation. **Not** `admin@local` / `admin`; generate fresh.
   - `DEX_TRACCAR_CLIENT_SECRET` — Traccar's Dex OIDC client secret.

### Phase 6 — gtfs application layer ✅ DONE (authored)
- **Dex** (`gtfs/dex/`) — upstream `ghcr.io/dexidp/dex:v2.44.0`, config in a
  hash-suffixed ConfigMap via `configMapGenerator`; Postgres host `postgres-rw`.
- **oauth2-proxy** — `v7.8.2` Deployment + Service :4180; the TF ForwardAuth labels
  became two Traefik `Middleware` CRDs (`oauth2-proxy`, `oauth2-errors`).
- **rt-api** — two Deployments off `cafe-car:1bc7074`: `gtfs-api` (:8000) and
  `gtfs-manager` (:8001).
- **rt-api-migrate** — `railroad-club-migrate` as an ArgoCD **PreSync hook Job**.
- **celery** — worker + beat off `schedule-foamer:1deff09`; beat uses `Recreate`.
- **uptime-kuma** — `louislam/uptime-kuma:1` + Longhorn PVC 2Gi + Service :3001.
- Secrets are injected as dependent env vars (`$(POSTGRES_RT_API_PASSWORD)` inside
  the DSN); private images use `imagePullSecrets: [registry-git-kcfam]`.

### Phase 6a — ingest layer + application refresh ⬜ TODO ← **the main remaining work**

**1. Traccar** (`gtfs/traccar/`)
- Deployment `traccar/traccar:6.14.5`; Services `traccar` (:8082) and
  `traccar-osmand` (:5055) — or one Service with both ports.
- `traccar.xml` as a ConfigMap, ported from `music-student`'s `dev/traccar/traccar.xml`:
  - `database.url` → `jdbc:postgresql://postgres-rw:5432/traccar`, user `traccar`.
  - `web.url` → `https://traccar.gtfs.zone`.
  - `openid.clientId=traccar`, `openid.issuerUrl=https://dex.gtfs.zone`, secret from Secret.
  - `forward.enable=true`, `forward.type=json`,
    `forward.url=http://vehicle-poser:8080/forward`, `forward.retry.enable=true`.
    **Do not** switch to `forward.type=redis` — it LPUSHes raw Position JSON with
    no TTL and no `trip_id`.
  - ⚠️ Keep secrets out of the ConfigMap: set `CONFIG_USE_ENVIRONMENT_VARIABLES=true`
    and inject `DATABASE_PASSWORD` / `OPENID_CLIENTSECRET` from Secrets. **Verify**
    this override works on 6.14.5 before relying on it; fall back to an initContainer
    that templates `traccar.xml` from env.
- **Retention CronJob** — Traccar has *no* retention config key; it stores every fix
  forever. Port `music-student`'s `scripts/traccar_retention.sql` into a nightly
  `CronJob` (psql image + CNPG credentials, default 30 days).
- Add a **`traccar` static client** to `gtfs/dex/config.yaml` with redirect URI
  `https://traccar.gtfs.zone/` (secret from `gtfs-app-secrets`).

**2. vehicle-poser** (`gtfs/vehicle-poser.yaml`) — resurrected, now HTTP-mode.
Deployment + Service :8080. Env: `HTTP_PORT=8080`,
`REDIS_URL=redis://redis:6379/1`,
`DATABASE_URL=postgresql+psycopg2://rt_api:$(POSTGRES_RT_API_PASSWORD)@postgres-rw:5432/rt_api`.
Leave `VEHICLE_KEY_PREFIX` at its `vehicle` default (the shadow prefix was a
dual-run tool; we are not dual-running). Internal only — **no IngressRoute**.

**3. hell-gate-bridge** (`gtfs/hell-gate-bridge.yaml`) — two Deployments off one image:
- `hell-gate-bridge-amtrak`: `SOURCE=amtrak`, `POLL_INTERVAL=15`,
  `INGEST_VEHICLE_ID=amtrak-live`.
- `hell-gate-bridge-buswhere`: `SOURCE=buswhere`, `INGEST_VEHICLE_ID=columbia-county`,
  `GTFS_URL=https://raw.githubusercontent.com/columbia-county-ny-transit/gtfs-generator/refs/heads/main/columbia_county_gtfs.zip`
  (the raw URL — the `/raw/` form 302s and hell-gate's httpx client does not follow redirects).
- Both: `CAFE_CAR_INGEST_URL=http://gtfs-api:8000`, `INGEST_API_TOKEN` from Secret,
  and a small **Longhorn PVC each** for `/app/beat` (GTFS cache + poller state).
- `INGEST_VEHICLE_ID` must equal a provisioned `Tracker.id` (Phase 8 step).

**4. Refresh what Phase 6 already authored** to match the shipped app stack:
- Dex `v2.44.0` → **`v2.45.0`**; oauth2-proxy `v7.8.2` → **`v7.14.3`**.
- Re-pin `cafe-car` and `schedule-foamer` images to the post-merge main builds
  (current pins predate the Traccar work).
- rt-api (both Deployments) gains `TRACCAR_URL=http://traccar:8082`,
  `TRACCAR_EMAIL`, `TRACCAR_PASSWORD`, `TRACCAR_CLIENT_BASE=https://traccar.gtfs.zone/osmand`,
  `INGEST_API_TOKEN`, and a production `CORS_ALLOWED_ORIGINS`.
- Drop the leftover `MQTT_PUBLIC_PASSWORD` env from rt-api — MQTT is gone for good.

### Phase 7 — Ingress & edge cutover ⬜ TODO
1. `gtfs/ingressroutes.yaml` — one `IngressRoute` (websecure, `gtfs-zone-tls`) per host:
   - `rt` → gtfs-api:8000 (public)
   - `manage.rt` → gtfs-manager:8001 **+ oauth2 middlewares**
   - `dex` → dex:5556 · `auth` → oauth2-proxy:4180
   - `uptime` → uptime-kuma:3001 **+ oauth2 middlewares** · `status` → uptime-kuma:3001 (public)
   - `traccar` → two rules: `PathPrefix(/osmand)` → traccar-osmand:5055 with a
     `StripPrefix` middleware, and the default rule → traccar:8082. Public (no oauth2).
   - ArgoCD's own route comes from `infra/argocd/`.
   All carry the external-dns annotations that create the Porkbun records.
2. ⚠️ **Edit `home-docker` Traefik** dynamic config: TCP router
   ``HostSNIRegexp(`^.+\.gtfs\.zone$`)`` on `websecure`, `tls.passthrough=true`,
   forwarding to `HOST_GATEWAY_IP:8443`. Keep the global `:80 → :443` redirect.
   Then `tofu apply` in the home-docker repo. **This is the only home-docker change**,
   and it already covers Traccar — no new ports, no IngressRouteTCP.

### Phase 8 — Bring-up & verify ⬜ TODO
Follow `music-student`'s `startup-guide.md`, adapted to prod hostnames:
1. `curl https://rt.gtfs.zone/health`; confirm the served cert is cert-manager's.
2. Sign in at `https://manage.rt.gtfs.zone` (oauth2-proxy → Dex → connector). First
   admin login creates the owner `User` row that `Feed.owner_id` needs.
3. **Bootstrap the Traccar admin** — a fresh Traccar DB has no users; the first
   `POST /api/users` (allowed while `tc_users` is empty) becomes administrator.
   Use the generated `TRACCAR_ADMIN_*` credentials, then verify `administrator = t`.
4. Enable **Registration** (`PUT /api/server {"registration": true}`) so Dex logins
   auto-provision manager accounts.
5. Provision the three feeds (amtrak, columbia-county, west) and their `Tracker`s;
   the two poller `INGEST_VEHICLE_ID`s must match the provisioned tracker ids.
6. West/driver path: generate the QR from the manage app, scan with Traccar Client,
   confirm a position lands in Redis (`vehicle:{tracker_id}:*`) and surfaces in the feed.
7. Celery beat enqueues static GTFS loads; worker processes them.
8. `https://argocd.gtfs.zone` reachable; all Applications Synced + Healthy;
   external-dns created the expected Porkbun records.

### Phase 9 — Decommission (aggressive — no uptime concern) ⬜ TODO
1. `cd tf && tofu destroy`. Volumes have `prevent_destroy`; remove those blocks or
   `tofu state rm` + `docker volume rm`. **We are abandoning this data intentionally.**
2. `git rm -r tf/ tf-monitors/ nanomq/ traefik/ dex/` on this branch. (`tf-monitors/`
   configures Uptime Kuma via the Docker stack's API — re-do later if wanted.)
3. Rewrite `CLAUDE.md` for the k8s/ArgoCD layout (the migration banner and the whole
   Terraform section go away). Update `README.md`'s architecture section.
4. Delete `TRACCAR_MIGRATION_FEASIBILITY.md` or mark it **superseded** — the design
   it studies has shipped.

### Phase 10 — Branch hygiene & handoff ⬜ TODO
1. Push the pending local commits (currently **4 ahead** of `origin/k3s-init` —
   Phases 4 and 6 have never reached ArgoCD).
2. Delete the three stale remote branches — all already squash-merged into `main`:
   `51-driver-rules` (→ `a151afd`), `52-apply-copier` (→ `6b7813a`),
   `feature/13-add-cz` (→ `6cee30b`).
3. Open **one PR**: `k3s-init` → `main`.
4. After merge, flip `apps/root.yaml` `targetRevision` `k3s-init` → `main` and
   `kubectl apply` it once (ArgoCD cannot follow a branch it is no longer tracking).
5. Delete `k3s-init`.

---

## Docker → Kubernetes mapping

| Today (Docker/TF) | Kubernetes | Notes |
|---|---|---|
| `traefik` container + custom image | Traefik **Helm** (infra) | Upstream image; host :8443 via ServiceLB |
| `postgres` + `postgres-init` | **CNPG `Cluster`** | Declarative roles/dbs (`rt_api`, `dex`, `traccar`); Longhorn |
| `redis` | Deployment + Service + PVC | Longhorn-backed |
| `dex` + custom image | Deployment + ConfigMap | Upstream `dexidp/dex` v2.45.0 |
| `oauth2-proxy` | Deployment + Middleware | ForwardAuth → Traefik `Middleware` CRD |
| `gtfs-migrate` (init) | **ArgoCD PreSync Job** | Alembic before rollout |
| `gtfs-api` / `gtfs-manager` | 2 Deployments + Services | Same image, different command/port |
| `celery-worker` / `celery-beat` | 2 Deployments | Internal only |
| `uptime-kuma` | Deployment + PVC | `docker.sock` monitors dropped |
| — (new) | **Traccar** Deployment + ConfigMap + 2 Services + retention CronJob | Replaces OwnTracks/NanoMQ ingest |
| `vehicle-poser` (MQTT bridge) | Deployment + Service :8080 | Now an **HTTP forward receiver**, not MQTT |
| — (new) | **hell-gate-bridge** ×2 Deployments + PVCs | Amtrak + Columbia County pollers |
| `nanomq`, `trip-updogger` | **deleted** | Retired upstream; not coming back |
| Traefik container **labels** | `IngressRoute` / `Middleware` | HTTP only |
| `random_password` resources | SOPS-encrypted `Secret`s | Regenerated fresh |
| `dns.tf` (Porkbun) | **external-dns** | Records from IngressRoute annotations |
| `traefik_letsencrypt` volume | **gone** | cert-manager issues certs as Secrets |

---

## Manual / sudo steps (things YOU run)

1. Install `open-iscsi`/`nfs-common` + enable `iscsid`. — Phase 1
2. Install k3s (`--disable traefik`). — Phase 1
3. Copy kubeconfig off the server. — Phase 1
4. Create the `sops-age` Secret in `argocd`. — Phase 2 ✅
5. `kubectl apply -f apps/root.yaml` once to bootstrap. — Phase 2 ✅
6. Merge the three app repos to `main` so CI publishes images. — before Phase 6a
7. Edit home-docker Traefik for the `*.gtfs.zone` passthrough + `tofu apply`. — Phase 7
8. Bootstrap the Traccar admin user + enable Registration; provision feeds/trackers;
   scan the driver QR. — Phase 8
9. `tofu destroy` the old gtfs Docker stack. — Phase 9
10. Re-apply `apps/root.yaml` with `targetRevision: main`. — Phase 10

Everything else flows through git → ArgoCD.

---

## Known gaps carried over from the Traccar design

Documented in `music-student`'s `docs/traccar.md`; **not** blockers, but they land
in prod with us:

1. **Managers see no devices by default** — Traccar scopes device visibility
   per-user and cafe-car creates fleet devices as the admin account. A fresh
   OIDC-provisioned manager sees an empty list until devices are shared
   (`POST /api/permissions`).
2. **Dex users can't auto-become admin** — static passwords emit no `groups` claim,
   so `openid.adminGroup` matches nothing. The internal admin account stays the way in.
3. **The QR / `uniqueId` is a bearer credential** — anyone who photographs it can
   impersonate that tracker. Accepted for public transit data.
4. **`registration=true` is required** for OIDC manager auto-provisioning, which also
   exposes self-service registration in the web UI. Prod hardening (deferred):
   `openid.force=true` to hide the internal login form entirely.

---

## Suggested follow-ups (post-migration)

- **Renovate** (or ArgoCD Image Updater) for image-tag bumps via PRs.
- **CNPG scheduled backups** + Longhorn snapshots to object storage — now that
  Traccar keeps durable position history, this matters more than it did.
- **Prometheus/Grafana** scraping the cluster; re-do the `tf-monitors/` Uptime Kuma
  config as manifests or drop it.
- **Per-device tokens / plausibility filtering** for tracker identity hardening.
- **Migrate `home-docker` into the same cluster** app-by-app, making k3s the single
  edge and retiring the Docker Traefik — the original end-state.
