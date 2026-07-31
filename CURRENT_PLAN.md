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

> **Revision 2026-07-31 (later).** Phases 5a, 6a and 7 are **authored and
> pushed** (`3f1cc67`); all four app repos are merged to `main` with images
> published. The two open risks this plan carried — Traccar's env-var config
> override and the `/osmand` path split — were **tested against
> `traccar/traccar:6.14.5` and both resolved favourably**; details in the phases
> below. What remains is Phase 8 (bring-up, currently blocked on Longhorn),
> Phase 9 and Phase 10.

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
phone-report protocol port). The Traccar Client takes a full URL from the QR code,
so the path is ours to choose. This avoids a second, confusable hostname.

✅ **No `StripPrefix` needed** — verified against 6.14.5 that the osmand decoder
ignores the request path entirely and reads only query parameters (`POST
/osmand?id=…` and `POST /?id=…` both store the position). The `gps.gtfs.zone`
fallback is not needed.

The web console is **not** behind oauth2-proxy — Traccar does its own Dex OIDC —
and `/osmand` must stay unauthenticated (phones authenticate by device `uniqueId`
only, and have no browser session).

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

✅ **Upstream app-repo prerequisite — DONE (2026-07-31).** All four repos are
merged to `main`, all four images verified pullable from the registry:

| Repo | Image tag pinned in manifests |
|---|---|
| `cafe-car` | `git.kcfam.us/gtfs.zone/cafe-car:b190bb0` |
| `vehicle-poser` | `git.kcfam.us/gtfs.zone/vehicle-poser:0135419` |
| `schedule-foamer` | `git.kcfam.us/gtfs.zone/schedule-foamer:348af9f` |
| `hell-gate-bridge` | `git.kcfam.us/gtfs.zone/hell-gate-bridge:57f2581` |
| `railroad-club` | `main` — migrations already include Tracker/TrackerRule |

⚠️ **CI publishes `:latest` + `:<short-sha>` only — there is no `:main` tag.**
Don't reach for one. Bumping an image is a manifest edit + commit.

**Copier is retired.** `.copier-answers.yml` removed from every app repo;
`.mcp.json` kept (it is a working forgejo-mcp config, not template bookkeeping).
`forgejo-mcp` is installed at `~/go/bin/forgejo-mcp` — useful for opening the
Phase 10 PR, since `gh` only knows github.com and `tea` is not installed.

All `random_password` values are **regenerated fresh** — we are not migrating data.

---

## Phased plan

### Phase 0 — Prep ✅ DONE
- age keypair for SOPS. Public recipient (in `.sops.yaml`):
  `age16mxws3n4s0my6k5jzy225shmpa36ag35v975xg4j6u7k3rjqn5dqvxw27c`.
  Private key `age.key` at repo root — **gitignored**; back it up out-of-band.
- Skeleton `apps/ infra/ gtfs/` created on branch `k3s-init`.
- ✅ **host-gateway IP confirmed:** `172.18.0.1` — the **proxy-tier** bridge
  gateway (the network home-docker's Traefik is attached to), *not* the
  `172.17.0.1` default bridge this note originally pointed at.

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

### Phase 5a — stateful layer delta for Traccar ✅ DONE (authored, `3f1cc67`)
1. **`traccar` role + database** on the CNPG cluster, mirroring `dex`:
   `gtfs/secrets/postgres-traccar.enc.yaml` (basic-auth), a `managed.roles`
   entry, and a `Database` CR (`owner: traccar`). Traccar migrates its own schema.
2. Postgres PVC stays **10Gi**; `tc_positions` growth is bounded by the retention
   CronJob (Phase 6a), not by sizing.
3. Added to `gtfs/secrets/gtfs-app-secrets.enc.yaml`, all freshly generated:
   `INGEST_API_TOKEN`, `TRACCAR_ADMIN_EMAIL` (`admin@gtfs.zone`),
   `TRACCAR_ADMIN_PASSWORD`, `DEX_TRACCAR_CLIENT_SECRET`.

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

### Phase 6a — ingest layer + application refresh ✅ DONE (authored, `3f1cc67`)

**1. Traccar** (`gtfs/traccar/`) — Deployment `traccar/traccar:6.14.5`
(`strategy: Recreate`, single writer), Services `traccar` (:8082) and
`traccar-osmand` (:5055), `traccar.xml` in a hash-suffixed ConfigMap, and the
retention CronJob. Ported from `music-student`'s `dev/traccar/traccar.xml` with
prod hosts. `forward.type=json` → `http://vehicle-poser:8080/forward`;
**not** `forward.type=redis`, which LPUSHes raw Position JSON with no TTL and no
`trip_id`.

✅ **`CONFIG_USE_ENVIRONMENT_VARIABLES=true` verified on 6.14.5.** Tested by
booting the image against a real Postgres with a `traccar.xml` whose
`database.url`/`user`/`password` were all deliberately wrong: env won on every
key and Liquibase ran the full changelog. `DATABASE_PASSWORD` and
`OPENID_CLIENTSECRET` therefore come from Secrets and stay out of the ConfigMap.
**The initContainer-templating fallback is not needed.** (Traccar's mapping is
the config key uppercased with dots dropped: `openid.clientSecret` →
`OPENID_CLIENTSECRET`.)

- **Retention CronJob** — nightly 04:10, `ghcr.io/cloudnative-pg/postgresql:18.3`
  running `retention.sql` (a 30-day port of `music-student`'s
  `scripts/traccar_retention.sql`) as the `traccar` role. Required, not optional:
  6.14.5 has no retention config key and keeps every fix forever.
- A **`traccar` static client** was added to `gtfs/dex/config.yaml`
  (redirect URI `https://traccar.gtfs.zone/`, secret from `gtfs-app-secrets`).

**2. vehicle-poser** (`gtfs/vehicle-poser.yaml`) — Deployment + Service :8080,
`HTTP_PORT=8080`, `REDIS_URL=redis://redis:6379/1`, psycopg2 `DATABASE_URL`
against `postgres-rw`. `VEHICLE_KEY_PREFIX` left at its `vehicle` default (the
shadow prefix was a dual-run tool). Internal only — no IngressRoute.
⚠️ `REDIS_URL`/`DATABASE_URL` are read with `os.environ[...]` at **module scope**,
so a missing or malformed value crashes the pod at import, not at first request.

**3. hell-gate-bridge** (`gtfs/hell-gate-bridge.yaml`) — two Deployments off one
image, `amtrak` (`INGEST_VEHICLE_ID=amtrak-live`, `POLL_INTERVAL=15`) and
`buswhere` (`INGEST_VEHICLE_ID=columbia-county`, raw-githubusercontent `GTFS_URL`
— the `/raw/` form 302s and hell-gate's httpx client does not follow redirects).

⚠️ **Deviation from the original plan: no PVC on `/app/beat`.** The image creates
and chowns that directory for the non-root `bridge` user at build time; mounting a
volume over it masks the chown and the poller dies with `PermissionError` writing
`gtfs_cache.zip`. The only thing living there is a re-downloadable GTFS cache, so
the image's own directory is simpler and safer.

⚠️ `INGEST_API_TOKEN` unset sends a literal `Bearer None` rather than erroring —
a missing secret surfaces as 401s at cafe-car, not a crash. Check it in Phase 8.

**4. Refresh of the Phase 6 manifests** — Dex → `v2.45.0`, oauth2-proxy →
`v7.14.3`, all four images repinned, rt-api gained `TRACCAR_URL`,
`TRACCAR_CLIENT_BASE=https://traccar.gtfs.zone/osmand`, `TRACCAR_EMAIL`,
`TRACCAR_PASSWORD`, `INGEST_API_TOKEN` and a prod `CORS_ALLOWED_ORIGINS`;
`MQTT_PUBLIC_PASSWORD` dropped.

**Three latent bugs found and fixed while authoring this phase** — each would
have broken the first sync:
1. rt-api ran `fastapi run src/app/main.py`; the package is **`src/cafe_car`**.
   Both Deployments would have crash-looped.
2. celery-beat had no `--schedule`, so it would write its shelve DB to the
   root-owned `/app` while running as non-root `bridge`. Now `/app/beat/`.
3. external-dns had been crash-looping for 8 days (2068 restarts) on
   `traefik.containo.us`, a legacy API group Traefik v3 does not ship.
   `--traefik-disable-legacy` added to `infra/external-dns/values.yaml`.

### Phase 7 — Ingress & edge cutover ✅ DONE (authored, `3f1cc67`)
1. `gtfs/ingressroutes.yaml` — seven IngressRoutes on `websecure` with
   `gtfs-zone-tls`, each carrying
   `external-dns.alpha.kubernetes.io/target: 73.4.232.254`:
   `rt` (public), `manage.rt` (+oauth2), `dex`, `auth`, `uptime` (+oauth2),
   `status` (public), and `traccar`. ArgoCD's own route still comes from
   `infra/argocd/` and is **not yet authored** — see Phase 8.

   ✅ **The Traccar `/osmand` split needs no StripPrefix.** Verified against
   6.14.5 that the osmand decoder ignores the request path entirely and reads only
   query params: `POST /osmand?id=…` and `POST /?id=…` both returned 200 and
   stored the position. The middleware was dropped, and the `gps.gtfs.zone`
   fallback is **not needed**.

2. `home-docker/traefik/dynamic/gtfs-zone-passthrough.yml` is **written but not
   applied** — needs `tofu apply` in `home-docker` (the dynamic dir is baked into
   the locally-built Traefik image). TCP router
   ``HostSNIRegexp(`^.+\.gtfs\.zone$`)`` on `websecure`, `tls.passthrough=true`.

   ⚠️ **Correction to this plan's Phase 0 note:** the target is **`172.18.0.1:8443`**,
   the **proxy-tier** bridge gateway that home-docker's Traefik is actually attached
   to — *not* the `172.17.0.1` default-bridge gateway. Re-derive with
   `docker network inspect proxy-tier --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'`.
   The regex deliberately excludes the bare apex `gtfs.zone`, which stays on
   home-docker's static-sites container (landing-zone).

### Phase 8 — Bring-up & verify ⬜ TODO ← **the remaining work**

**Cluster state as of the `3f1cc67` push** (`ssh -N -L 6443:127.0.0.1:6443 kcfam`
for kubectl access — the kubeconfig points at `127.0.0.1:6443`):

| Application | State | Note |
|---|---|---|
| `root`, `infra-traefik`, `infra-cnpg`, `infra-cert-manager`, `infra-cert-manager-webhook-porkbun` | Synced/Healthy | fine |
| `infra-longhorn` | **OutOfSync / Missing** | ← blocks everything below |
| `infra-external-dns` | Progressing | picking up `--traefik-disable-legacy` |
| `infra-cert-manager-config` | Progressing | cert can't issue until Porkbun secret lands |
| `gtfs` | OutOfSync / Degraded | PVCs Pending on the missing StorageClass |
| `infra-secrets` | **did not exist** before this push | Phase 4 had never reached ArgoCD |

**0. Unblock Longhorn first — nothing else can start without it.** Only
`local-path` exists as a StorageClass, so the CNPG initdb Job and the Redis pod
have been Pending for 8 days. The sync failed at revision `01836fa` and ArgoCD
refuses to retry *the same* revision ("Skipping auto-sync: failed previous sync
attempt … and will not retry"), which is why it stayed stuck. Established facts:
`iscsid` is **active** on the node and `iscsiadm` is present, and
`helm template … | kubectl apply --server-side --dry-run=server` applies cleanly
— so the original failure looks environmental and already resolved. The new
revision should let auto-sync retry on its own; if it doesn't, sync it manually
and read the real per-resource error before changing anything.
(`nfs-common` is missing on the node but is only needed for RWX volumes, which we
don't use. `sudo apt-get install -y nfs-common` if you want it anyway.)

**1. ArgoCD has no IngressRoute yet.** `infra/argocd/values.yaml` still notes
"Until the IngressRoute exists (Phase 7) access is via kubectl port-forward" —
step 8 below needs one authored (host `argocd.gtfs.zone`, the argocd-server
Service, `gtfs-zone-tls`, external-dns target annotation). It was **not** part of
`gtfs/ingressroutes.yaml` because it lives in the `argocd` namespace.

Then follow `music-student`'s `startup-guide.md`, adapted to prod hostnames:
1. `curl https://rt.gtfs.zone/health`; confirm the served cert is cert-manager's.
2. Sign in at `https://manage.rt.gtfs.zone` (oauth2-proxy → Dex → connector). First
   admin login creates the owner `User` row that `Feed.owner_id` needs.
3. **Bootstrap the Traccar admin** — a fresh Traccar DB has no users; the first
   `POST /api/users` (allowed while `tc_users` is empty) becomes administrator.
   Use the generated `TRACCAR_ADMIN_*` credentials, then verify `administrator = t`.
   ✅ Rehearsed locally against 6.14.5: `POST /api/users` on an empty `tc_users`
   returned `"administrator": true`, and creating a device with those credentials
   then worked. The `TRACCAR_ADMIN_EMAIL`/`_PASSWORD` in `gtfs-app-secrets` are
   the ones rt-api already uses for device auto-provisioning, so bootstrap with
   exactly those values or cafe-car cannot talk to Traccar.
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
1. ✅ Local commits pushed — `origin/k3s-init` is at `3f1cc67`.
2. ✅ Stale branches gone in every repo. In the four app repos the merged feature
   branches were deleted locally and remotely; each is now `main`-only.
3. Open **one PR**: `k3s-init` → `main`. `gh` only knows github.com and `tea` is
   not installed, but **`forgejo-mcp` is at `~/go/bin/forgejo-mcp`** and needs
   `FORGEJO_ACCESS_TOKEN` — otherwise do it in the Forgejo web UI.
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

1. ✅ Install `open-iscsi` + enable `iscsid`. — Phase 1 (`nfs-common` still absent;
   only matters for RWX volumes, which we don't use)
2. ✅ Install k3s (`--disable traefik`). — Phase 1 (`kcfam-deb`, v1.36.2+k3s1)
3. ✅ Copy kubeconfig off the server. — Phase 1. It points at `127.0.0.1:6443`, so
   every kubectl session needs `ssh -N -L 6443:127.0.0.1:6443 kcfam` running.
4. ✅ Create the `sops-age` Secret in `argocd`. — Phase 2
5. ✅ `kubectl apply -f apps/root.yaml` once to bootstrap. — Phase 2
6. ✅ Merge the app repos to `main` so CI publishes images. — before Phase 6a
7. `tofu apply` in **home-docker** to ship the already-written
   `traefik/dynamic/gtfs-zone-passthrough.yml` (the dynamic dir is baked into the
   locally-built Traefik image, so a rebuild is required). — Phase 7
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
