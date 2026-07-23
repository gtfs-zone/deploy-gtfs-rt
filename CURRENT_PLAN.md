# Plan: Migrate deploy-gtfs-rt to k3s + ArgoCD

Migrate the `gtfs.zone` stack from OpenTofu-managed Docker containers to a
GitOps-managed Kubernetes deployment on a single-node **k3s** cluster, driven by
**ArgoCD**. This is a pilot for eventually moving the whole server (including the
`home-docker` / `kcfam.us` stack) to k3s, so we set up the "industry standard"
patterns now even though the project is small.

---

## Locked decisions

| Decision | Choice | Why |
|---|---|---|
| **Scope** | Migrate `gtfs.zone` only; `home-docker` stays on Docker for now | Data gravity — gtfs data is disposable; home-docker holds irreplaceable Nextcloud/Immich data + Forgejo (which serves our images). Pilot on the cheap stack. |
| **MQTT subsystem** | **Dropped for now** — no NanoMQ, no vehicle-poser, no trip-updogger, no MQTT ingress | Removes the L4/SNI-passthrough complexity and the shared-passwd-volume wrinkle entirely. Re-introduce later as a follow-up. |
| **Repo layout** | Top-level `apps/`, `infra/`, `gtfs/` in **this** repo; delete `tf/` at the end | Keep history in one place; manifests replace Terraform in the same repo. |
| **Secrets** | **SOPS + age**, decrypted in ArgoCD via **KSOPS** (kustomize plugin) | Portable GitOps secret pattern; secrets are normal YAML you can diff/rotate. |
| **Edge (80/443)** | `home-docker` Traefik stays the edge; **SNI-passthrough** `*.gtfs.zone` → k3s Traefik on host port 8443 | Least disruptive; k3s still fully owns gtfs.zone TLS via cert-manager. Now HTTP-only (no MQTT), so passthrough is pure HTTPS SNI. |
| **DNS** | **external-dns** (Porkbun webhook) from day one | No blocker to doing it now; retires `dns.tf` and manages records from Ingress. |
| **Data** | **Start fresh** — no volume migration | Nothing in the gtfs Postgres/Redis is valuable; re-run migrations + re-enter feeds. |
| **Storage** | **Longhorn** (not local-path) | Chosen for a future multi-node cluster; gives replicated volumes + snapshots/backups. |
| **Postgres** | **CloudNativePG** operator | The standard way to run Postgres on k8s: declarative users/dbs, backups, failover-ready. |
| **Custom images** | Drop locally-built `traefik`/`dex` images → upstream images + mounted config | Removes a build/push pipeline; config-as-ConfigMap is the k8s-native pattern. (NanoMQ image gone with the MQTT drop.) |

---

## Target architecture

```
                          Internet  (one public IP = server_ip)
                               │  :80 / :443
                               ▼
                 ┌──────────────────────────────┐
                 │  home-docker Traefik (Docker) │   ← unchanged, still owns 80/443
                 │  *.kcfam.us  → terminate here │
                 │  *.gtfs.zone → TCP passthrough│───┐  (HostSNIRegexp, tls.passthrough)
                 └──────────────────────────────┘   │
                                                     ▼  host:8443 (k3s ServiceLB)
                 ┌──────────────────────────────────────────────────────┐
                 │  k3s single node                                      │
                 │                                                       │
                 │  Traefik (Helm)  ── websecure entrypoint (:8443)      │
                 │    └─ IngressRoute  rt / manage / dex / auth /        │
                 │                     uptime / status / argocd          │
                 │                                                       │
                 │  cert-manager  ── Porkbun DNS-01 ClusterIssuer        │
                 │    └─ *.gtfs.zone cert  → Secret                      │
                 │  external-dns  ── Porkbun webhook (manages records)   │
                 │  Longhorn      ── replicated storage / snapshots      │
                 │                                                       │
                 │  ArgoCD  ── watches this git repo (app-of-apps)       │
                 │                                                       │
                 │  gtfs namespace:                                      │
                 │    CloudNativePG (postgres) · Redis                   │
                 │    Dex · oauth2-proxy · rt-api (api + manager)        │
                 │    celery worker/beat · uptime-kuma                   │
                 └──────────────────────────────────────────────────────┘
```

**Port fact:** with MQTT gone, all gtfs traffic is plain HTTPS on 443 by SNI
hostname. home-docker passes `*.gtfs.zone` through to k3s Traefik on host **8443**,
which terminates TLS and routes by Host. No IngressRouteTCP, no alt ports.

---

## Repo structure (end state)

```
deploy-gtfs-rt/
├── apps/                      # ArgoCD Application manifests (app-of-apps root)
│   ├── root.yaml              # the "app of apps" — points ArgoCD at apps/
│   ├── infra-longhorn.yaml
│   ├── infra-traefik.yaml
│   ├── infra-cert-manager.yaml
│   ├── infra-external-dns.yaml
│   ├── infra-cnpg.yaml
│   └── gtfs.yaml              # the gtfs stack Application
├── infra/                     # cluster-wide platform pieces (Helm value overlays)
│   ├── longhorn/              # Helm values (default StorageClass)
│   ├── traefik/               # Helm values: entrypoint, ServiceLB port 8443
│   ├── cert-manager/          # Helm values + ClusterIssuer + Porkbun webhook
│   ├── external-dns/          # Helm values + Porkbun webhook provider
│   ├── cnpg/                  # CloudNativePG operator (Helm)
│   └── argocd/                # ArgoCD's own values + its IngressRoute
├── gtfs/                      # the application stack (Kustomize)
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── postgres-cluster.yaml  # CNPG Cluster + declarative users/dbs
│   ├── redis.yaml
│   ├── dex/                   # Deployment + ConfigMap
│   ├── oauth2-proxy.yaml
│   ├── rt-api.yaml            # gtfs-api + gtfs-manager Deployments + Services
│   ├── rt-api-migrate.yaml    # ArgoCD PreSync hook Job (Alembic)
│   ├── celery.yaml            # worker + beat
│   ├── uptime-kuma.yaml
│   ├── ingressroutes.yaml     # HTTP routers + oauth2 middlewares
│   └── secrets/               # SOPS-encrypted Secrets (*.enc.yaml)
├── tf/                        # DELETE once cutover verified (kept during transition)
└── CURRENT_PLAN.md
```

**Conventions (industry standard):**
- **Third-party components** (Longhorn, Traefik, cert-manager, external-dns, CNPG,
  ArgoCD) → their official **Helm charts**, referenced from ArgoCD `Application`s
  with a `helm` source + a values file in `infra/`.
- **Our own workloads** → plain manifests assembled with **Kustomize**.
- **App-of-apps**: one root `Application` (`apps/root.yaml`) points at `apps/`; each
  file there is an `Application`. Adding a component = add one file.
- **Namespaces**: `gtfs`, `argocd`, `cert-manager`, `traefik`, `external-dns`,
  `cnpg-system`, `longhorn-system`.

---

## Prerequisites & credentials

- SSH/sudo access to the server.
- **Porkbun API key + secret** (from `tf/secrets.auto.tfvars`) — reused for
  cert-manager DNS-01 **and** external-dns.
- **Registry pull credentials** for `git.kcfam.us` (Forgejo) — for private images
  (`cafe-car` used by rt-api; `schedule-foamer` used by celery).
- The **OAuth connector secrets** (GitHub/Google/GitLab) used by Dex, if enabled.
- Workstation tools: `kubectl`, `helm`, `kustomize`, `sops`, `age`, `argocd`.

All the `random_password` values are **regenerated fresh** (we're not migrating data).

---

## Phased plan

### Phase 0 — Prep (no server changes) ✅ DONE
1. ✅ Note the host-gateway IP a Docker container uses to reach host ports (usually
   `172.17.0.1`) — the passthrough target for home-docker Traefik.
2. ✅ Create the `apps/ infra/ gtfs/` skeleton in this repo (branch `k3s-init`).
3. ✅ Generate an **age keypair** for SOPS: `age-keygen -o age.key` (private key stays
   OUT of git; public key goes in `.sops.yaml`).

**Phase 0 outputs:**
- **age public recipient** (in `.sops.yaml`):
  `age16mxws3n4s0my6k5jzy225shmpa36ag35v975xg4j6u7k3rjqn5dqvxw27c`
  The private key is `age.key` at the repo root — **gitignored**; becomes the
  `sops-age` Secret in Phase 2. Back it up out-of-band; losing it makes every
  encrypted Secret unrecoverable.
- **host-gateway IP**: the workstation's Docker `bridge` gateway is `192.168.222.1`
  (non-default pool). ⚠️ **Must be re-confirmed on the actual server** in Phase 7 —
  run `docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'`
  on the home-docker host; that value (not the workstation's) is the passthrough target.
- Skeleton dirs created with `.gitkeep` placeholders per the end-state layout above.

### Phase 1 — Install k3s  ⚠️ MANUAL / sudo on the server
```bash
# Longhorn needs open-iscsi on the host:
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

# Disable bundled Traefik (we manage our own); keep servicelb (klipper) for host ports.
curl -sfL https://get.k3s.io | sudo sh -s - \
  --disable traefik \
  --write-kubeconfig-mode 644
```
Then copy `/etc/rancher/k3s/k3s.yaml` to your workstation as `~/.kube/config` and fix
the `server:` field to the server's reachable IP. Verify: `kubectl get nodes`.
- ServiceLB will bind whatever host port our Traefik `LoadBalancer` Service requests
  — we request **8443** (never 80/443) so we never collide with the Docker Traefik.

### Phase 2 — Bootstrap ArgoCD  ✅ DONE
```bash
kubectl create namespace argocd
kubectl -n argocd create secret generic sops-age --from-file=keys.txt=age.key  # root of trust
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --version 10.1.4 -f infra/argocd/values.yaml
kubectl apply -f apps/root.yaml     # bootstrap app-of-apps
```
- Configured **KSOPS** as a Config Management Plugin sidecar on the argocd-repo-server
  (via `infra/argocd/values.yaml`), with the age private key mounted from a Secret.
- Bootstrapped app-of-apps once; ArgoCD now self-manages from git.
- ArgoCD served at `argocd.gtfs.zone` via its own IngressRoute (`infra/argocd/`) — **deferred to
  Phase 7** (needs Traefik + cert-manager). Access initially via
  `kubectl -n argocd port-forward svc/argocd-server 8080:443`.

**Phase 2 outputs:**
- **Workstation tools installed:** `helm` v4.2.3, `argocd` v3.4.5. (`sops`/`age`/`kustomize`
  still not installed — not needed until Phase 4; KSOPS runs inside the sidecar, not locally.)
  `kubectl` reaches the API server through an SSH tunnel: `ssh -fN -L 6443:localhost:6443 kcfam`.
- **Chart:** `argo/argo-cd` **10.1.4** (appVersion **v3.4.5**), namespace `argocd`. All pods
  Running; `argocd-repo-server` is **2/2** (main + `ksops` sidecar).
- **KSOPS sidecar** (`infra/argocd/values.yaml`): `viaductoss/ksops:v4.3.3` initContainer copies
  `ksops` + a ksops-enabled `kustomize` (**v5.3.0+ksops.v4.3.3**) into the sidecar; sidecar runs
  `argocd-cmp-server` with `SOPS_AGE_KEY_FILE=/home/argocd/.config/sops/age/keys.txt`. Plugin
  `ksops` discovers any app tree containing `*.enc.yaml` and renders via
  `kustomize build --enable-alpha-plugins --enable-exec`. Verified inside the pod (binary present,
  plugin.yaml mounted, age key readable).
- **`sops-age` Secret** created in `argocd` from `age.key` (key `keys.txt`) — out-of-band root of
  trust, not in git.
- **`server.insecure: true`** set (TLS terminated upstream by Traefik in Phase 7).
- **app-of-apps** (`apps/root.yaml`): root `Application` → **HTTPS** repo
  `https://git.kcfam.us/gtfs.zone/deploy-gtfs-rt.git`, path `apps/`, `targetRevision: k3s-init`,
  automated sync + prune + selfHeal. ⚠️ **Deviation:** repo is **anonymously readable over HTTPS**,
  so we use the HTTPS URL and need **no ArgoCD repo credential** (the plan's SSH assumption is moot).
  Status: **Synced + Healthy** at commit `80dd80f`, 0 child resources (empty until Phase 3).
- ⚠️ **TODO:** flip `targetRevision` `k3s-init` → `main` once the migration is merged.
- **Initial admin password:** `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

### Phase 3 — Infra layer (via ArgoCD)  ✅ DONE (authored; syncs on push)
Add these `Application`s under `apps/`:
1. **Longhorn** (`infra/longhorn/`): Helm install; set as **default StorageClass**.
   On a single node it keeps 1 replica; scales when nodes are added.
2. **Traefik** (`infra/traefik/`): one `websecure` entrypoint; `Service.type=LoadBalancer`
   on host **port 8443**; enable CRDs (IngressRoute/Middleware). No ACME (certs from
   cert-manager).
3. **cert-manager** (`infra/cert-manager/`): Helm install + a **Porkbun DNS-01
   `ClusterIssuer`** using the **cert-manager Porkbun webhook**; Porkbun creds from a
   SOPS Secret. A `Certificate` for `*.gtfs.zone` (+ apex SANs) → `tls` Secret in `gtfs`.
4. **external-dns** (`infra/external-dns/`): Helm install with the **Porkbun webhook
   provider**; source = Traefik `IngressRoute`; target = `server_ip`. Manages all
   `*.gtfs.zone` records from annotations, retiring `dns.tf`.
5. **CloudNativePG operator** (`infra/cnpg/`): Helm install of the operator only.

**Phase 3 outputs:**
- **Pattern:** every infra chart is an ArgoCD **multi-source** `Application` — the
  upstream Helm chart + `$values/infra/<comp>/values.yaml` read from THIS git repo
  (the standard "Helm chart + in-repo values" pattern). Raw CRs (ClusterIssuer,
  Certificate) go through a plain directory-source `Application`. All carry
  `ServerSideApply=true` (large CRDs) + `CreateNamespace=true` and automated
  sync/prune/selfHeal.
- **Applications added** under `apps/` (with `sync-wave` ordering):
  - `infra-longhorn` (wave 0) → `longhorn` **1.8.1**, ns `longhorn-system`, default SC, 1 replica.
  - `infra-cnpg` (wave 0) → `cloudnative-pg` **0.28.0** (operator only), ns `cnpg-system`.
  - `infra-cert-manager` (wave 0) → `cert-manager` **v1.17.4**, ns `cert-manager`, CRDs kept.
  - `infra-traefik` (wave 1) → `traefik` **35.2.0**, ns `traefik`; **only** websecure
    exposed, `LoadBalancer` publishing host **8443** (klipper); web(:80) kept internal so
    it never collides with the Docker Traefik; CRD provider on, Ingress provider off.
  - `infra-cert-manager-webhook-porkbun` (wave 1) → Talinx `cert-manager-webhook-porkbun`
    **1.0.0** (image pinned `1.0.0`), group `porkbun.talinx.dev`.
  - `infra-external-dns` (wave 1) → sigs `external-dns` **1.16.1**, ns `external-dns`,
    Porkbun **webhook provider** `ghcr.io/konnektr-io/external-dns-porkbun-webhook:v0.2.19`,
    source `traefik-proxy`, `domainFilters: [gtfs.zone]`, `policy: sync`, owner `gtfs-k3s`.
  - `infra-cert-manager-config` (wave 2) → directory source `infra/cert-manager/manifests/`:
    `ClusterIssuer letsencrypt-porkbun` (LE prod, DNS-01 webhook) + `Certificate gtfs-zone-tls`
    (`gtfs.zone` + `*.gtfs.zone` → Secret `gtfs-zone-tls` in ns `gtfs`).
- ⚠️ **Deviations from the plan's file list:** cert-manager is split into **three**
  Applications (operator / webhook / config) instead of one, so each is a single-purpose
  sync unit. The `gtfs` namespace is created early (by `infra-cert-manager-config`) rather
  than only in Phase 5 — the later gtfs `Namespace` manifest adopts it.
- **Secret dependencies (Phase 4):** both the cert-manager webhook and external-dns
  reference a `porkbun-secret` Secret (in `cert-manager` / `external-dns` namespaces
  respectively) that does **not exist yet**. Until Phase 4 authors it, external-dns
  CrashLoops and the `gtfs-zone-tls` Certificate stays Pending — expected.
- **Activation:** ArgoCD watches git, so these only take effect once the branch is
  **pushed** to `git.kcfam.us` (root app tracks `k3s-init`). No `kubectl apply` needed.

### Phase 4 — Secrets (SOPS)  ✅ DONE (authored + encrypted; syncs on push)
- Create `.sops.yaml` with the age recipient + rules matching `**/secrets/*.enc.yaml`
  and `infra/**/*.enc.yaml`.
- Author encrypted Secrets (`sops secrets/foo.enc.yaml`):
  - `porkbun` — API key/secret for cert-manager webhook **and** external-dns.
  - `registry-git-kcfam` — a `dockerconfigjson` imagePullSecret for the private
    Forgejo images; referenced by rt-api and celery pods.
  - `gtfs-app-secrets` — the ex-`random_password` values: postgres per-service
    passwords, `SESSION_SECRET_KEY`, oauth2-proxy cookie secret, Dex↔oauth2-proxy
    shared client secret, OAuth connector secrets. Generate fresh (`openssl rand -hex 32`).
- Circular-dependency note: the imagePullSecret targets `git.kcfam.us` (home-docker
  Forgejo) — fine, home-docker stays up throughout.

**Phase 4 outputs:**
- **`.sops.yaml`** already existed from Phase 0/2 (age recipient
  `age16mxws3n4s0my6k5jzy225shmpa36ag35v975xg4j6u7k3rjqn5dqvxw27c`, rules for
  `(^|/)secrets/.*\.enc\.yaml$` and `^infra/.*\.enc\.yaml$`) — reused, not recreated.
- **Pattern:** each secret tree is a KSOPS-rendered Kustomize dir — a
  `kustomization.yaml` (`generators: [./secret-generator.yaml]`) + a `ksops`
  `secret-generator.yaml` listing the `*.enc.yaml` files. The plain presence of
  `*.enc.yaml` triggers ArgoCD's ksops CMP discovery, which runs
  `kustomize build --enable-alpha-plugins --enable-exec .`. Verified locally with
  that exact command (sops 3.9.4 / kustomize 5.3.0 / ksops 4.3.3) — all four
  Secrets decrypt + render correctly.
- **`porkbun` split into two Secrets** (deviation): each consumer wants different
  key names in a different namespace, so `porkbun-secret` exists twice —
  `infra/secrets/porkbun-cert-manager.enc.yaml` (ns `cert-manager`, keys
  `PORKBUN_API_KEY`/`PORKBUN_SECRET_API_KEY`) and
  `infra/secrets/porkbun-external-dns.enc.yaml` (ns `external-dns`, keys
  `API_KEY`/`API_SECRET`). Both wrapped by `infra/secrets/kustomization.yaml`.
- **New Application** `apps/infra-secrets.yaml` (wave 2, ksops CMP source at
  `infra/secrets`) applies both Porkbun Secrets. Wave 2 = after cert-manager (0)
  and external-dns (1) create their namespaces. Once synced, external-dns stops
  CrashLooping and the `gtfs-zone-tls` Certificate can issue — closing the Phase 3
  secret dependency.
- **gtfs Secrets authored** under `gtfs/secrets/` (encrypted now; wired into the
  gtfs Kustomize app in Phase 5/6, so **no** Application yet):
  - `gtfs-app-secrets.enc.yaml` (ns `gtfs`, 12 keys): `POSTGRES_ADMIN_PASSWORD`,
    `POSTGRES_DEX_PASSWORD`, `POSTGRES_RT_API_PASSWORD` (fresh `openssl rand`),
    `DEX_OAUTH2_PROXY_CLIENT_SECRET`, `OAUTH2_PROXY_COOKIE_SECRET` (32-byte),
    `SESSION_SECRET_KEY` (fresh), and the six GitHub/GitLab/Google connector
    `CLIENT_ID`/`CLIENT_SECRET` values carried over from `tf/secrets.auto.tfvars`.
  - `registry-git-kcfam.enc.yaml` (ns `gtfs`, `dockerconfigjson` for `git.kcfam.us`).
  - `gtfs/secrets/{kustomization,secret-generator}.yaml` reference both.
- ⚠️ **Local tooling:** `sops`/`age`/`kustomize`/`ksops` were installed to
  `~/.local/bin` (no sudo on this workstation). Re-encrypting/rotating secrets needs
  `PATH="$HOME/.local/bin:$PATH"` and `SOPS_AGE_KEY_FILE=<repo>/age.key`.
- **Activation:** ArgoCD renders these only after the branch is **pushed** to
  `git.kcfam.us` (KSOPS runs in the repo-server sidecar, not locally).

### Phase 5 — gtfs stateful layer  ✅ DONE (authored; syncs on push)
1. **Postgres via CNPG** (`gtfs/postgres-cluster.yaml`): a `Cluster` on Longhorn
   storage, with declarative bootstrap creating `dex` and `rt_api` roles+databases
   (replaces the `postgres-init` shell Job). Passwords from the SOPS Secret.
2. **Redis** (`gtfs/redis.yaml`): Deployment + Service + Longhorn PVC. Single Redis,
   DBs 0 (oauth2 sessions) / 1 (rt-api) / 3 (celery broker) / 4 (celery result).

**Phase 5 outputs:**
- **gtfs stack wired up.** Created the Kustomize root (`gtfs/kustomization.yaml` →
  `namespace.yaml` + `secrets` base + `postgres-cluster.yaml` + `redis.yaml`),
  `gtfs/namespace.yaml` (adopts the ns already made in Phase 3), and the **`gtfs`
  ArgoCD Application** (`apps/gtfs.yaml`, **wave 3** — after infra 0-2). Like
  `infra-secrets`, the Application sets **no** source type so ArgoCD's ksops CMP
  discovery renders the tree (`*.enc.yaml` present) via
  `kustomize build --enable-alpha-plugins --enable-exec`. Verified locally: the
  full tree builds and every Secret decrypts.
- **Postgres = CNPG `Cluster`** `postgres` (ns `gtfs`), **1 instance** on Longhorn
  (10Gi), image pinned `ghcr.io/cloudnative-pg/postgresql:18.3` (matches TF
  `postgres:18.3-alpine`; tag confirmed present on ghcr). Declarative replacement
  for the `postgres-init` Job:
  - `enableSuperuserAccess: true` + `superuserSecret: postgres-superuser` → the
    `postgres` superuser.
  - `bootstrap.initdb` (`database/owner: rt_api`, `secret: postgres-rt-api`) → the
    `rt_api` role **and** `rt_api` database.
  - `managed.roles: [dex]` (`passwordSecret: postgres-dex`) → the `dex` login role;
    a **`Database` CR** (`postgresql.cnpg.io/v1`, `owner: dex`) makes the `dex`
    database. (Split because `initdb` seeds only one database/owner.)
- **Redis** = Deployment (`redis:8.6-alpine`, `--appendonly yes`, `Recreate`
  strategy since it owns one RWO PVC) + Service (:6379) + Longhorn PVC `redis-data`
  (2Gi). No auth — internal-only, as in the Docker stack. Logical DB split (0/1/3/4)
  is unchanged and set by clients.
- ⚠️ **Deviation — Postgres passwords restructured into CNPG basic-auth Secrets.**
  CNPG's `superuserSecret` / `initdb.secret` / role `passwordSecret` all require
  `kubernetes.io/basic-auth` Secrets (`username`+`password`), so the three
  `POSTGRES_*_PASSWORD` keys were **removed** from `gtfs-app-secrets.enc.yaml`
  (via `sops unset`) and re-authored as dedicated SOPS Secrets in `gtfs/secrets/`:
  `postgres-superuser` (postgres), `postgres-dex` (dex), `postgres-rt-api` (rt_api)
  — same fresh password values, now single-source-of-truth. Phase 6 Dex/rt-api
  consume these directly. All three added to `gtfs/secrets/secret-generator.yaml`.
- **Activation:** ArgoCD renders/syncs only after the branch is **pushed** to
  `git.kcfam.us` (ksops runs in the repo-server sidecar). CNPG operator must be
  Healthy first (wave 0) — it is, per Phase 3.

### Phase 6 — gtfs application layer  ✅ DONE (authored; syncs on push)
Translate each remaining container to a `Deployment` + `Service`:
- **Dex** — upstream `dexidp/dex` + ConfigMap; Deployment + Service (:5556).
- **oauth2-proxy** — Deployment + Service (:4180); its ForwardAuth becomes a Traefik
  `Middleware` CRD (+ the errors/redirect middleware) applied to protected routes.
- **rt-api** — two Deployments off the same `cafe-car` image: `gtfs-api` (:8000,
  public) and `gtfs-manager` (:8001, admin) + Services.
- **rt-api migrate** — the Alembic step (`railroad-club-migrate`) becomes an **ArgoCD
  PreSync hook `Job`** (`gtfs/rt-api-migrate.yaml`), running before the Deployments roll.
- **celery worker + beat** — two Deployments off `schedule-foamer`, internal only.
- **uptime-kuma** — Deployment + Longhorn PVC.

**Phase 6 outputs:**
- **Six manifests added** to the gtfs Kustomize tree (all appended to
  `gtfs/kustomization.yaml`): `dex/` (component dir), `oauth2-proxy.yaml`,
  `rt-api.yaml`, `rt-api-migrate.yaml`, `celery.yaml`, `uptime-kuma.yaml`. Verified
  the whole tree builds + decrypts with
  `kustomize build --enable-alpha-plugins --enable-exec gtfs` (28 objects; the dex
  ConfigMap hash reference is correctly rewritten into the dex Deployment).
- **Dex** (`gtfs/dex/`): upstream `ghcr.io/dexidp/dex:v2.44.0` (drops the custom
  `kcfam/dex:local` image — the upstream image natively expands the config's
  `{{ getenv }}` templates). Config lives in `gtfs/dex/config.yaml`, rendered into a
  hash-suffixed `dex-config` ConfigMap by a **`configMapGenerator`** (a `dex/`
  sub-kustomization) so a config edit rolls the Deployment. Only change vs. the TF
  config: Postgres host `postgres` → **`postgres-rw`** (CNPG's read-write Service).
  DB password from the `postgres-dex` basic-auth Secret; issuer/redirect/connector
  env from `gtfs-app-secrets` (all three GitHub/GitLab/Google connectors, GitLab
  `baseURL` literal `https://gitlab.com`). TCP-socket probes on :5556 (dex's
  `/healthz` lives only on the unconfigured telemetry port).
- **oauth2-proxy** (`gtfs/oauth2-proxy.yaml`): `quay.io/oauth2-proxy/oauth2-proxy:v7.8.2`,
  Deployment + Service (:4180), `/ping` probes. The TF ForwardAuth **labels become two
  Traefik `Middleware` CRDs** in ns `gtfs` — `oauth2-proxy` (forwardAuth →
  `oauth2-proxy.gtfs.svc:4180/oauth2/auth`, copies the three `X-Auth-Request-*`
  headers) and `oauth2-errors` (401-403 → inline sign-in via the oauth2-proxy
  Service). Phase 7 IngressRoutes attach them to `manage.rt` + `uptime`.
- **rt-api** (`gtfs/rt-api.yaml`): two Deployments + Services off
  `git.kcfam.us/gtfs.zone/cafe-car:1bc7074` — `gtfs-api` (:8000, `/health` probes)
  and `gtfs-manager` (:8001). Shared env mirrors TF `local.rt_api_env`.
- **rt-api migrate** (`gtfs/rt-api-migrate.yaml`): `railroad-club-migrate` as an
  ArgoCD **PreSync hook `Job`** (`hook-delete-policy: BeforeHookCreation`,
  `backoffLimit: 3`, `restartPolicy: Never`).
- **celery** (`gtfs/celery.yaml`): `celery-worker` + `celery-beat` Deployments off
  `schedule-foamer:1deff09`, internal (no Service). beat uses `Recreate` (single
  scheduler). Env mirrors TF `local.schedule_foamer_env` (concurrency 2, recycle 10;
  psycopg2 driver DSN).
- **uptime-kuma** (`gtfs/uptime-kuma.yaml`): `louislam/uptime-kuma:1`, Deployment +
  Longhorn PVC (2Gi, `Recreate`) + Service (:3001).
- ⚠️ **Deviations from the TF stack:**
  - **DATABASE_URL password injected via a dependent env var** — `POSTGRES_RT_API_PASSWORD`
    (secretKeyRef → `postgres-rt-api`) referenced as `$(POSTGRES_RT_API_PASSWORD)`
    inside the DSN, since the password lives in a Secret, not the manifest. Same
    pattern in rt-api, migrate Job, and celery.
  - **oauth2-proxy cookie secret passed raw** (32-byte value from `gtfs-app-secrets`),
    not `base64encode`d as the TF did — oauth2-proxy accepts a 32-byte string directly.
  - **`/run/nanomq` shared volume dropped** from rt-api (MQTT subsystem gone);
    `MQTT_PUBLIC_PASSWORD=public` env kept (harmless, image may read it).
  - **uptime-kuma `docker.sock` mount dropped** (Docker container monitors don't
    apply on k8s).
  - **Private images use `imagePullSecrets: [registry-git-kcfam]`** (the Phase 4
    dockerconfigjson Secret) on rt-api, migrate, and celery pods.
- **Not yet exposed:** no `IngressRoute`s or DNS — Dex/oauth2-proxy/rt-api/uptime are
  reachable only in-cluster until **Phase 7** wires the edge.
- **Activation:** ArgoCD renders/syncs only after the branch is **pushed** to
  `git.kcfam.us`. On sync the PreSync migrate Job runs first, then the Deployments roll.

### Phase 7 — Ingress & edge cutover
1. `gtfs/ingressroutes.yaml`: an `IngressRoute` (websecure) per HTTP host — `rt`,
   `manage.rt`, `dex`, `auth`, `uptime`, `status` — referencing the cert-manager `tls`
   Secret, plus the oauth2-proxy forward-auth `Middleware` on `manage.rt` and `uptime`.
   (ArgoCD gets its route from `infra/argocd/`.) These carry the external-dns
   annotations that create the DNS records.
2. ⚠️ **Edit `home-docker` Traefik** dynamic config: add a TCP router
   `HostSNIRegexp(\`^.+\\.gtfs\\.zone$\`)` on `websecure`, `tls.passthrough=true`,
   forwarding to `HOST_GATEWAY_IP:8443`. Only change to home-docker. Keep its global
   `:80 → :443` redirect. Then `tofu apply` in the home-docker repo.

### Phase 8 — Verify
- `curl -v https://rt.gtfs.zone/health` (public API) — served cert is cert-manager's.
- Sign-in at `https://manage.rt.gtfs.zone` (oauth2-proxy → Dex → connector).
- Celery beat enqueues + worker processes feed loads; re-add a feed via the manage UI
  and confirm ingest.
- `https://argocd.gtfs.zone` reachable; all Applications `Healthy` + `Synced`.
- external-dns created the expected Porkbun records.

### Phase 9 — Decommission
1. `cd tf && tofu destroy` (gtfs Docker stack only). Volumes have `prevent_destroy` —
   remove those blocks or `tofu state rm` + manual `docker volume rm` (we're
   abandoning the data intentionally).
2. Delete `tf/` and the now-unused `traefik/`, `dex/` (and `nanomq/`) image-build dirs.
3. Update `CLAUDE.md` to describe the k8s/ArgoCD layout.

---

## Docker → Kubernetes mapping

| Today (Docker/TF) | Kubernetes | Notes |
|---|---|---|
| `traefik` container + custom image | Traefik **Helm** (infra) | Upstream image; host :8443 via ServiceLB |
| `postgres` + `postgres-init` | **CNPG `Cluster`** | Declarative roles/dbs replace the init Job; on Longhorn |
| `redis` | Deployment + Service + PVC | Longhorn-backed |
| `dex` + custom image | Deployment + ConfigMap | Upstream `dexidp/dex` |
| `oauth2-proxy` | Deployment + Middleware | ForwardAuth → Traefik `Middleware` CRD |
| `gtfs-migrate` (init) | **ArgoCD PreSync Job** | Alembic before rollout |
| `gtfs-api` / `gtfs-manager` | 2 Deployments + Services | Same image, different command/port |
| `celery-worker` / `celery-beat` | 2 Deployments | Internal only |
| `uptime-kuma` | Deployment + PVC | Longhorn-backed |
| `nanomq`, `vehicle-poser`, `trip-updogger` | **dropped** | MQTT subsystem deferred |
| Traefik container **labels** | `IngressRoute` / `Middleware` | HTTP only now |
| `random_password` resources | SOPS-encrypted `Secret`s | Regenerated fresh |
| `dns.tf` (Porkbun) | **external-dns** | Records from IngressRoute annotations |
| `traefik_letsencrypt` volume | **gone** | cert-manager issues certs as Secrets |

---

## Manual / sudo steps summary (things YOU run on the server)

1. **Install open-iscsi/nfs-common** + enable `iscsid` (Longhorn prereq). — Phase 1
2. **Install k3s** (`curl … | sudo sh -s - --disable traefik …`). — Phase 1
3. **Copy kubeconfig** off the server. — Phase 1
4. **Create the `sops-age` Secret** in `argocd` (root of trust). — Phase 2
5. **`kubectl apply -f apps/root.yaml`** once to bootstrap. — Phase 2
6. **Edit home-docker Traefik** to add the `*.gtfs.zone` passthrough, then `tofu apply`
   in the home-docker repo. — Phase 7
7. **`tofu destroy`** the old gtfs Docker stack. — Phase 9

Everything else flows through git → ArgoCD.

---

## Resolved
- **MQTT deferral — confirmed.** Dropping NanoMQ + vehicle-poser + trip-updogger +
  MQTT ingress will break realtime ingest; that's accepted and will be addressed
  separately (see `TRACCAR_MIGRATION_FEASIBILITY.md`), not by re-adding NanoMQ.
- **OAuth connectors — keep all three** (GitHub/Google/GitLab). Carry all connector
  secrets into `gtfs-app-secrets`.

---

## Suggested follow-ups (post-migration)
- **Restore realtime ingest** per `TRACCAR_MIGRATION_FEASIBILITY.md`. If that design
  still needs an L4/TCP listener, it slots in as a `gtfs/…` overlay with an
  `IngressRouteTCP` (`HostSNI`) on the same 8443 entrypoint — home-docker's existing
  `*.gtfs.zone` passthrough already covers it, so no edge change is required.
- **Renovate** (or ArgoCD Image Updater) for image-tag bumps via PRs.
- **CNPG scheduled backups** + **Longhorn snapshots/backups** to object storage.
- **Prometheus/Grafana** (or reuse home-docker's) scraping the cluster.
- **Migrate `home-docker` into the same cluster** app-by-app, making k3s the single
  edge and retiring the Docker Traefik — the original end-state.
