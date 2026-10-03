# gtfs-zone-infra

[![CI](https://img.shields.io/github/actions/workflow/status/gtfs-zone/gtfs-zone-infra/check.yml?branch=main&label=CI)](https://github.com/gtfs-zone/gtfs-zone-infra/actions/workflows/check.yml?query=branch%3Amain) [![License: AGPL-3.0-or-later](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE.txt)

**GTFS.Zone** is a "public option" for transit operators to publish real-time
GTFS feeds. The goal is to make it as simple, lightweight, and inexpensive as
possible: a small agency with minimal technical resources should be able to
get a live feed running in an afternoon.

Operators who don't want to self-host can use an already-running instance
without touching any of this. This repo is for those who want to run their own.

### How it fits together

The stack is built from these open-source projects:

| Project | Role |
|---------|------|
| [gtfs-zone-rt-api](https://github.com/gtfs-zone/gtfs-zone-rt-api) | Core API, serves GTFS-RT feeds and handles admin |
| [gtfs-zone-rt-traccar-receiver](https://github.com/gtfs-zone/gtfs-zone-rt-traccar-receiver) | Receives Traccar position forwards over HTTP → Redis |
| [gtfs-zone-rt-delay-estimator](https://github.com/gtfs-zone/gtfs-zone-rt-delay-estimator) | Sweeps live positions against the schedule → trip updates in Redis |
| [gtfs-zone-rt-pollers](https://github.com/gtfs-zone/gtfs-zone-rt-pollers) | Polls upstream feeds (Amtrak, Columbia County) → rt-api |
| [gtfs-zone-static-importer](https://github.com/gtfs-zone/gtfs-zone-static-importer) | Celery worker + beat scheduler for async static GTFS fetching |
| [gtfs-zone-db-models](https://github.com/gtfs-zone/gtfs-zone-db-models) | Shared SQLAlchemy models and Alembic migrations |
| [gtfs-zone-dev-stack](https://github.com/gtfs-zone/gtfs-zone-dev-stack) | Docker Compose stack for local development and testing |
| [gtfs-zone-homepage](https://github.com/gtfs-zone/gtfs-zone-homepage) | Static homepage at gtfs.zone |
| [gtfs-zone-feed-catalog](https://github.com/gtfs-zone/gtfs-zone-feed-catalog) | Dagster pipeline: the GTFS source catalog, its reachability checks and logical feeds, published to data.gtfs.zone |
| [gtfs-zone-feed-list](https://github.com/gtfs-zone/gtfs-zone-feed-list) | list.gtfs.zone, the source catalog as a list and a world map |
| [gtfs-zone-editor](https://github.com/gtfs-zone/gtfs-zone-editor) | GTFS editor at edit.gtfs.zone |
| [gtfs-zone-rt-viewer](https://github.com/gtfs-zone/gtfs-zone-rt-viewer) | Realtime visualiser at viz.rt.gtfs.zone |
| [gtfs-zone-rt-manager](https://github.com/gtfs-zone/gtfs-zone-rt-manager) | Admin SPA at manage.rt.gtfs.zone, on rt-api's JSON API |
| [gtfs-zone-timetable-sites](https://github.com/gtfs-zone/gtfs-zone-timetable-sites) | Static timetable sites at sites.gtfs.zone, a Dagster code location in feed-catalog's instance |
| [gtfs-zone-web-common](https://github.com/gtfs-zone/gtfs-zone-web-common) | Shared browser library and app shell for the editor, rt-viewer, rt-manager and feed-list |

This repo provides the Kubernetes (k3s + ArgoCD) deployment that wires them
together with supporting infrastructure.

```mermaid
flowchart LR
    classDef repo fill:#dbeafe,stroke:#3b82f6,color:#1e3a5f
    classDef dir fill:#fef9c3,stroke:#d97706,color:#5c3d00
    classDef gitops fill:#dcfce7,stroke:#16a34a,color:#14532d

    apps[["`**apps/**<br>ArgoCD Applications`"]]:::gitops
    infra["`**infra/**<br>Helm values + CRs`"]:::dir
    gtfsd["`**gtfs/**<br>Kustomize app stack`"]:::dir
    argo(["`**ArgoCD**<br>watches this repo`"]):::gitops

    apps --> argo
    infra --> apps
    gtfsd --> apps

    subgraph registry["Container Registry"]
        cc(["**rt-api**<br>GTFS-RT API + admin"]):::repo
        vp(["**rt-traccar-receiver**<br>Traccar → Redis shim"]):::repo
        tu(["**rt-delay-estimator**<br>positions → trip updates"]):::repo
        hgb(["**rt-pollers**<br>upstream feed pollers"]):::repo
        sf(["**static-importer**<br>GTFS Static Downloader"]):::repo
        gc(["**feed-catalog**<br>source catalog pipeline"]):::repo
    end

    rc(["**gtfs-zone-db-models**<br>SQLAlchemy models + migrations"]):::repo
    ms(["**gtfs-zone-dev-stack**<br>local dev Compose"]):::repo

    rc -->|"models + migrations"| cc
    rc -->|"models"| vp
    rc -->|"models"| sf

    cc & vp & tu & hgb & sf & gc -->|"container image"| gtfsd

    gtfsd -.-|"mirrors for local dev"| ms
```

**Issues:** [issue tracker](https://github.com/gtfs-zone/gtfs-zone-infra/issues)

---

## What you get

| URL | Service |
|-----|---------|
| `rt.<domain>` | Public GTFS-RT feed API |
| `manage.rt.<domain>` | Admin UI (auth-gated) |
| `auth.<domain>` | oauth2-proxy sign-in |
| `id.<domain>` | Keycloak OIDC provider (brokers GitHub/Google/GitLab) |
| `traccar.<domain>` | Traccar console; `/osmand` takes phone position reports |
| `status.<domain>` | Public status page (Gatus) |
| `argocd.<domain>` | ArgoCD UI |
| `data.<domain>` | Public source-catalog artifacts (`feeds.json`, `sources.json`, ...) from Garage's public bucket |
| `dagster.<domain>` | Dagster UI for feed-catalog (gated on the `gtfs-admins` group) |
| `list.<domain>` | Source catalog list and world map (feed-list) |
| `edit.<domain>` | GTFS editor (gtfs-zone-editor) |
| `viz.rt.<domain>` | Realtime visualiser (gtfs-zone-rt-viewer) |


## System Diagrams

### Real-time data flow

A position update travels from a driver's phone to a GTFS-RT consumer in under a second.

```mermaid
sequenceDiagram
    actor driver as Driver<br>(Traccar Client app)
    actor operator as Operator
    participant mgr as rt-api admin
    participant tc as Traccar
    participant vp as rt-traccar-receiver
    participant tu as rt-delay-estimator
    participant hgb as rt-pollers
    participant Redis@{ "type": "database" }
    participant postgres@{ "type": "database" }
    participant pub as rt-api public
    actor consumer as GTFS Consumer<br>(Google Maps, etc.)

    Note over driver,tc: Device provisioning
    operator->>mgr: create tracker
    mgr->>tc: POST /api/devices (admin creds)
    mgr-->>operator: QR code (contains /osmand URL + uniqueId)
    driver->>driver: scan QR into Traccar Client

    Note over driver,Redis: Real-time position update
    driver->>tc: POST /osmand?id=…&lat=…&lon= (HTTPS)
    tc->>vp: forward.type=json → POST /forward
    vp->>postgres: resolve tracker → trip
    vp->>Redis: SET vehicle:{tracker}:{vehicle} (60s TTL)

    Note over tu,Redis: Delay derivation
    tu->>Redis: sweep vehicle:*
    tu->>postgres: load the trip's stop_times
    tu->>Redis: SET trip_update:{tracker}:{trip_id} (300s TTL)

    Note over hgb,pub: Upstream feed polling
    hgb->>hgb: poll Amtrak / Columbia County
    hgb->>pub: POST /ingest/position + /ingest/trip-update (bearer)
    pub->>Redis: store positions & delays

    Note over operator,mgr: Admin
    operator->>mgr: POST /alerts
    mgr->>postgres: INSERT service_alert
    postgres-->>mgr: ok
    mgr-->>operator: 201 Created

    Note over pub,consumer: Vehicle Positions
    consumer->>pub: GET /{feed}/vehicle_positions.pb
    pub->>Redis: read vehicle:*
    Redis-->>pub: positions
    pub-->>consumer: VehiclePosition FeedMessage

    Note over pub,consumer: Trip Updates
    consumer->>pub: GET /{feed}/trip_updates.pb
    pub->>Redis: read trip_update:*
    Redis-->>pub: delays
    pub-->>consumer: TripUpdate FeedMessage

    Note over pub,consumer: Service Alerts
    consumer->>pub: GET /{feed}/service_alerts.pb
    pub->>postgres: SELECT service_alerts
    postgres-->>pub: alerts
    pub-->>consumer: Alert FeedMessage
```

### System context

External actors and systems the stack integrates with.

```mermaid
flowchart LR
    driver(["Driver<br>(Traccar Client app)"])
    operator(["Transit Operator"])
    consumer(["GTFS Consumer<br>(Google Maps, etc.)"])

    traccar_app["Traccar Client<br>Free & open source GPS tracker app"]
    oauth["OAuth Provider<br>GitHub / GitLab / Google"]
    porkbun["Porkbun DNS<br>DNS-01 certs + external-dns records"]
    gtfs_src["Static GTFS Source<br>Agency schedule ZIP files"]
    upstream["Upstream RT feeds<br>Amtrak · Columbia County"]

    stack["GTFS.Zone Stack<br>(k3s + ArgoCD)"]

    driver -->|"drives with"| traccar_app
    traccar_app -->|"HTTPS /osmand"| stack
    operator -->|"admin UI"| stack
    stack -->|"GTFS-RT protobuf"| consumer
    stack -->|"DNS + cert management"| porkbun
    oauth -->|"OIDC tokens"| stack
    stack -->|"fetch schedule"| gtfs_src
    upstream -->|"polled by rt-pollers"| stack
```

### Core data model

All models defined in [gtfs-zone-db-models](https://github.com/gtfs-zone/gtfs-zone-db-models) and shared across services.

```mermaid
erDiagram
    USER {
        int id PK
        string primary_email
        string display_name
        datetime created_at
    }
    IDENTITY {
        int id PK
        int user_id FK
        string provider
        string provider_subject
        string email
        boolean email_verified
        datetime linked_at
        datetime last_seen_at
    }
    FEED_MEMBER {
        int id PK
        int feed_id FK
        int user_id FK
        int added_by_user_id FK
        datetime created_at
    }
    FEED_INVITE {
        int id PK
        int feed_id FK
        string email
        int invited_by_user_id FK
        int claimed_user_id FK
        datetime claimed_at
        datetime created_at
    }
    FEED {
        int id PK
        string feed_name
        string static_feed_url
        int owner_id FK
        int gtfs_static_feed_id FK
    }
    TRACKER {
        string id PK
        string nickname
        int feed_id FK
    }
    TRACKER_RULE {
        int id PK
        string tracker_id FK
        string trip_id
        boolean monday
        boolean tuesday
        boolean wednesday
        boolean thursday
        boolean friday
        boolean saturday
        boolean sunday
        time start_time
        time end_time
    }
    SERVICE_ALERT {
        int id PK
        int feed_id FK
        string header_text
        string description_text
        string url
        string cause
        string effect
        string severity_level
        datetime active_period_start
        datetime active_period_end
    }
    INFORMED_ENTITY {
        int id PK
        int service_alert_id FK
        string agency_id
        string route_id
        int route_type
        int direction_id
        string stop_id
        string trip_id
        string trip_route_id
        int trip_direction_id
        string trip_start_time
        string trip_start_date
    }
    GTFS_STATIC_FEED {
        int id PK
        string timezone
        string status
        string error_message
        datetime last_loaded_at
        datetime started_at
        datetime next_retry_at
    }
    GTFS_STOP {
        int id PK
        int gtfs_static_feed_id FK
        string stop_id
        string stop_name
        float stop_lat
        float stop_lon
        string stop_code
        string stop_desc
    }
    GTFS_ROUTE {
        int id PK
        int gtfs_static_feed_id FK
        string route_id
        string agency_id
        string route_short_name
        string route_long_name
        int route_type
    }
    GTFS_TRIP {
        int id PK
        int gtfs_static_feed_id FK
        string trip_id
        string route_id
        string service_id
        string trip_headsign
        int direction_id
    }
    GTFS_STOP_TIME {
        int id PK
        int gtfs_static_feed_id FK
        string trip_id
        string stop_id
        string arrival_time
        string departure_time
        int stop_sequence
    }

    USER ||--o{ IDENTITY : "signs in through"
    USER ||--o{ FEED : owns
    USER ||--o{ FEED_MEMBER : "is shared into"
    FEED ||--o{ FEED_MEMBER : "shared with"
    FEED ||--o{ FEED_INVITE : "pending invite"
    FEED }o--o| GTFS_STATIC_FEED : "loaded from"
    FEED ||--o{ TRACKER : has
    TRACKER ||--o{ TRACKER_RULE : has
    FEED ||--o{ SERVICE_ALERT : has
    SERVICE_ALERT ||--o{ INFORMED_ENTITY : targets
    GTFS_STATIC_FEED ||--o{ GTFS_STOP : contains
    GTFS_STATIC_FEED ||--o{ GTFS_ROUTE : contains
    GTFS_STATIC_FEED ||--o{ GTFS_TRIP : contains
    GTFS_STATIC_FEED ||--o{ GTFS_STOP_TIME : contains
```

### Service routing

Hostname routing from the internet through to each service, with data-layer
connections. The edge is home-docker's Traefik, which passes `*.gtfs.zone`
through untouched by SNI; the cluster's own Traefik terminates TLS.

```mermaid
stateDiagram-v2
    Internet : Internet
    edge : home-docker Traefik<br>owns :80/:443 · SNI passthrough for *.&ltdomain&gt
    tr : k3s Traefik<br>websecure :8443 · TLS from cert-manager
    tc : Traccar<br>:8082 console · :5055 osmand
    gt : Gatus
    ag : ArgoCD
    gw : Garage s3_web<br>public data.&ltdomain&gt bucket

    state "Auth" as auth {
        op : oauth2-proxy<br>ForwardAuth middleware
        opa : oauth2-proxy-admin<br>requires gtfs-admins
        kc : Keycloak<br>OIDC provider · brokers GitHub/Google/GitLab
    }

    state "rt-api" as application {
        cp : gtfs-api<br>public GTFS-RT feed
        ca : gtfs-manager<br>admin interface
    }

    state "Workers" as workers {
        vp : rt-traccar-receiver
        tu : rt-delay-estimator
        hgb : rt-pollers ×2
        sf : static-importer<br>Celery worker + beat
        gc : feed-catalog<br>Dagster webserver · daemon · code server
    }

    [*] --> Internet
    Internet --> edge
    edge --> tr : *.&ltdomain&gt (passthrough)

    tr --> cp : rt.&ltdomain&gt
    tr --> op : manage.rt / auth.&ltdomain&gt
    tr --> kc : id.&ltdomain&gt
    tr --> tc : traccar.&ltdomain&gt (+ /osmand)
    tr --> gt : status.&ltdomain&gt (public)
    tr --> ag : argocd.&ltdomain&gt
    tr --> gw : data.&ltdomain&gt (public)
    tr --> opa : dagster.&ltdomain&gt

    op --> ca : manage.rt.&ltdomain&gt (authed)
    op --> kc : OIDC token check
    opa --> gc : dagster.&ltdomain&gt (gtfs-admins)
    opa --> kc : OIDC token check
    gc --> gw : publishes artifacts (S3 API)

    tc --> vp : forward.type=json
    hgb --> cp : POST /ingest/*
```

### Object storage (Garage)

`gtfs/garage.yaml` runs a single-node `dxflrs/garage` StatefulSet with two
buckets, each reached with its own access key, so a leaked pipeline credential
reaches one bucket and not the other:

- `gtfs-feeds` is **private**, reachable only over the cluster-internal S3 API.
  It holds the GTFS zips uploaded through `manage.rt.gtfs.zone`: rt-api writes
  and serves them, static-importer reads them to load the schedule.
- `data.gtfs.zone` is **public**, written by feed-catalog over the S3 API and
  served read-only over plain HTTP by Garage's `s3_web` endpoint at
  `data.gtfs.zone`. Garage picks the bucket from the Host header, which is why
  the bucket's alias is literally the hostname and why the IngressRoute must not
  rewrite the Host.

Every writer talks the S3 API rather than Garage's own, so swapping in AWS, R2
or B2 later is a matter of changing `S3_ENDPOINT`. A `garage-init` Job (an
ArgoCD `PostSync` hook) applies the single-node layout, creates both buckets,
imports their keys and enables website access on the public one; Garage
refuses every S3 call until that runs.

### Source catalog

feed-catalog ingests Transitland Atlas and the Mobility Database once a day,
checks whether each endpoint answers, keeps history per normalized URL in its
own Postgres database, and publishes JSON to `data.gtfs.zone`. The frontends
read those artifacts at runtime rather than shipping a catalog baked in at build
time: the edit and viz load modals list `feeds.json`, and `list.gtfs.zone` draws
the whole catalog on a map.

```mermaid
flowchart LR
    tl["Transitland Atlas"]
    mdb["Mobility Database"]
    ex["curated examples"]
    gc["feed-catalog<br>Dagster, daily"]
    pg[("Postgres<br>feed_catalog")]
    bucket[("data.gtfs.zone<br>public bucket")]
    edit["edit / viz<br>load modal"]
    list["list.gtfs.zone"]

    tl & mdb & ex --> gc
    gc -->|"check history"| pg
    gc -->|"feeds.json · sources.json · status.json<br>examples.json · summary.json · manifest.json"| bucket
    bucket --> edit
    bucket --> list
```

Catalog rows (`sources.json`) are kept one per catalog entry and never merged.
Logical feeds (`feeds.json`) sit on top: one per transit system, bundling its
scheduled and realtime endpoints across catalogs, with ids that stay stable
across runs because they appear in shareable links.

### Real-time data pipeline

A position from a driver's phone becoming a GTFS-RT protobuf response.

```mermaid
flowchart LR
    driver(["Driver<br>Traccar Client app"])

    subgraph ingest["Ingest"]
        traccar["Traccar<br>/osmand :5055 · console :8082"]
        vp["rt-traccar-receiver<br>HTTP /forward"]
        hgb["rt-pollers<br>Amtrak · Columbia County"]
    end

    subgraph store["State"]
        redis[("Redis DB1<br>vehicle:{tracker}:{vehicle} 60s<br>trip_update:{tracker}:{trip} 300s")]
        pg[("Postgres<br>trackers · trips · alerts")]
    end

    tu["rt-delay-estimator<br>positions → delays"]
    api["rt-api gtfs-api"]
    consumer(["GTFS-RT consumer"])

    driver -->|"HTTPS POST /osmand"| traccar
    traccar -->|"forward json"| vp
    vp -->|"resolve tracker → trip"| pg
    vp --> redis
    redis -->|"sweep vehicle:*"| tu
    pg -->|"scheduled stop_times"| tu
    tu -->|"trip_update:*"| redis
    hgb -->|"POST /ingest/* (bearer)"| api
    api --> redis
    api --> pg
    api -->|"protobuf"| consumer
```

### Auth flow

How an operator reaches a protected service via Keycloak and oauth2-proxy.

```mermaid
stateDiagram-v2
    [*] --> Requesting: operator visits manage.rt.&ltdomain&gt

    state Requesting {
        [*] --> ForwardAuth: Traefik → oauth2-proxy
        ForwardAuth --> [*]: session valid
        ForwardAuth --> Login: no session
        Login --> [*]: cookie set
    }

    state Login {
        [*] --> Keycloak
        Keycloak --> OAuthProvider: redirect to GitHub / Google / GitLab
        OAuthProvider --> Keycloak: auth code
        Keycloak --> [*]: ID token (sub = Keycloak UUID) → session
    }

    Requesting --> Serving: authenticated

    state Serving {
        [*] --> Protected: rt-api admin
        Protected --> [*]: 200 OK
    }

    Serving --> [*]
```


## Development

```bash
# Install git hooks (required once per clone)
pre-commit install
```

There is **no imperative deploy step.** ArgoCD watches this repo and reconciles
the cluster to match it: you change YAML, commit, and push.

Before committing changes under `gtfs/`, render the tree the same way ArgoCD's
KSOPS plugin does:

```bash
PATH="$HOME/.local/bin:$PATH" SOPS_AGE_KEY_FILE=$PWD/age.key \
  kustomize build --enable-alpha-plugins --enable-exec gtfs
```

For changes under `infra/`, render the actual upstream chart with your values
rather than trusting the documented defaults:

```bash
helm template <release> <repo>/<chart> --version <v> -n <ns> -f infra/<comp>/values.yaml
```

### Cluster access

`kubectl` requires an SSH tunnel, since the kubeconfig points at `127.0.0.1:6443`.
Keep this running in a separate terminal:

```bash
ssh -N -L 6443:127.0.0.1:6443 kcfam
```

ArgoCD signs in through Keycloak ("Log in via Keycloak"), and authorizes on the
`argocd-admins` group; `argocd login argocd.gtfs.zone --sso` does the same for
the CLI. The local `admin` account stays enabled as break-glass, since Keycloak
depends on the database ArgoCD deploys:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Updating ArgoCD itself

ArgoCD is deliberately not self-managed, so `infra/argocd/values.yaml` is not
reconciled by a sync. Apply it by hand, always with `--version`, or the change
silently becomes an ArgoCD upgrade as well:

```bash
helm upgrade argocd argo/argo-cd -n argocd --version 10.1.4 -f infra/argocd/values.yaml
```

### Database access

Set up port-forward in a separate terminal:

```bash
kubectl -n gtfs port-forward svc/postgres-rw 5432:5432
```

Access via SQL (psql):

```bash
PGPASSWORD="$(kubectl -n gtfs get secret postgres-rt-api -o jsonpath='{.data.password}' | base64 -d)" \
  psql -h localhost -U rt_api -d rt_api
```

## Prerequisites

- **A server** with a public IP running [k3s](https://k3s.io/) (installed with
  `--disable traefik`; this repo brings its own via Helm) and `open-iscsi`
  enabled for Longhorn.
- **A domain on [Porkbun](https://porkbun.com/)** with API access enabled,
  used by both cert-manager (DNS-01) and external-dns.
- **At least one OAuth provider** (GitHub, GitLab, or Google) for user login.
- Local tooling: `kubectl`, `helm`, `kustomize`, `sops`, `age`, `ksops`.

> **Host tuning:** k3s, Longhorn and containerd share root's inotify quota. The
> default `fs.inotify.max_user_instances=128` is not enough and fails in
> confusing ways (processes silently unable to create file watchers). Set it to
> 1024 in `/etc/sysctl.d/`.

## Step 1: Domain and DNS API

1. Buy a domain at [porkbun.com](https://porkbun.com).
2. In your Porkbun account go to **API** → enable API access for the domain.
3. Generate an API key pair (`pk1_...` / `sk1_...`); you'll need both.

DNS records are **not** written by hand: external-dns creates them from the
`external-dns.alpha.kubernetes.io/target` annotation on each `IngressRoute`.
The bare apex is left alone deliberately.

## Step 2: OAuth app

Create an OAuth app with at least one provider. Use
`https://id.<your-domain>/realms/gtfs/broker/github/endpoint` as the authorization
callback URL. (Dex is gone; a `https://dex.<your-domain>/callback` entry left over
from before the cutover can be deleted.)

- **GitHub**: Settings → Developer settings → OAuth Apps → New OAuth App
- **GitLab**: User Settings → Applications
- **Google**: Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client ID (Web application)

## Step 3: Secrets (SOPS + age)

Secrets live in git, encrypted with [SOPS](https://github.com/getsops/sops) and
an [age](https://github.com/FiloSottile/age) key, and are decrypted inside the
cluster by a KSOPS plugin sidecar on the argocd-repo-server.

```bash
age-keygen -o age.key                      # keep this OUT of git (it is gitignored)
# put the public recipient in .sops.yaml, then edit secrets with:
sops infra/secrets/porkbun-secret.enc.yaml
sops gtfs/secrets/gtfs-app-secrets.enc.yaml
```

`sops set` updates a single value without printing plaintext. The age private
key must also exist in-cluster as the `sops-age` Secret in the `argocd`
namespace: that is the one piece of out-of-band bootstrap this design needs.

Populate at minimum:

- `infra/secrets/`: Porkbun API key/secret, once per consuming namespace
  (`cert-manager` uses `PORKBUN_API_KEY`/`PORKBUN_SECRET_API_KEY`,
  `external-dns` uses `API_KEY`/`API_SECRET`), plus `argocd-oidc.enc.yaml`
  (`clientSecret`), which argocd-server reads for Keycloak SSO. It must equal
  `KEYCLOAK_ARGOCD_CLIENT_SECRET` in `gtfs-app-secrets`, and must exist before
  ArgoCD starts with `oidc.config` set.
- `gtfs/secrets/gtfs-app-secrets.enc.yaml`: session key, the two oauth2-proxy
  cookie secrets (`OAUTH2_PROXY_COOKIE_SECRET`,
  `OAUTH2_PROXY_ADMIN_COOKIE_SECRET`), the Keycloak↔oauth2-proxy, ↔Traccar,
  ↔rt-api and ↔ArgoCD client secrets (`KEYCLOAK_*_CLIENT_SECRET`), the
  Keycloak bootstrap admin password, OAuth connector credentials,
  `INGEST_API_TOKEN`, the `TRACCAR_ADMIN_*` pair, the Garage secrets and both
  buckets' key pairs (`S3_*`, `FEED_CATALOG_S3_*`), feed-catalog's
  `MOBILITY_DB_REFRESH_TOKEN`, and the Gatus Telegram and heartbeat tokens.
- `gtfs/secrets/postgres-*.enc.yaml`: CNPG role passwords.

## Step 4: Bootstrap

Point the hostnames and the target IP at your own domain first: they are
referenced in `gtfs/ingressroutes.yaml`, `infra/argocd/manifests/ingress.yaml`,
`infra/cert-manager/manifests/`, `gtfs/keycloak/gtfs-realm.json` and
`gtfs/traccar/traccar.xml`.

```bash
# 1. install ArgoCD (once, out of band; it is deliberately NOT self-managed)
helm install argocd argo/argo-cd -n argocd --create-namespace --version 10.1.4 \
  -f infra/argocd/values.yaml

# 2. give it the age key so it can decrypt secrets
kubectl -n argocd create secret generic sops-age --from-file=keys.txt=age.key

# 3. hand it the repo; everything else follows from the app-of-apps
kubectl apply -f apps/root.yaml
```

Watch it converge with `kubectl get app -n argocd`. Sync waves bring things up in
order: storage/database operators → edge and DNS → issuers and secrets → the app.

On a cold bootstrap, ArgoCD's `oidc.config` references the `argocd-oidc` Secret
that step 3 is what creates, so the Keycloak login button does not work until
`infra-secrets` (wave 2) has synced. Use the local `admin` account until then;
the `argocd-admins` group membership also has to be assigned by hand, since
group membership is per-user and not part of the realm import.

## Step 5: First run

1. `curl https://rt.<domain>/health` should be 200 over a Let's Encrypt cert
   issued by cert-manager (not by whatever fronts your edge).
2. Sign in at `https://manage.rt.<domain>`; the first login creates the owner
   account that feeds are attached to.
3. Bootstrap Traccar: the first `POST /api/users` against an empty `tc_users`
   becomes administrator. **Use exactly the `TRACCAR_ADMIN_*` values from
   `gtfs-app-secrets`**: rt-api reuses them for device auto-provisioning, so a
   different password silently breaks the integration. Then enable registration
   (`PUT /api/server {"registration": true}`) so OIDC logins auto-provision.
4. Create feeds and their trackers, and make sure each poller's
   `INGEST_TRACKER_ID` matches a real tracker id: a mismatch produces no
   positions and no error.
5. Trigger feed-catalog's first run from `https://dagster.<domain>` rather than
   waiting for the schedule; `data.<domain>/manifest.json` appears once it
   finishes, and the load modals and `list.<domain>` are empty until then.

## Updating

Edit a manifest, commit, push. ArgoCD picks it up within a few minutes, or
immediately with:

```bash
kubectl annotate app <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

Image tags are pinned per workload. CI publishes `:vX.Y.Z` and `:latest` on
`v*` tags only, so bumping a version is a manifest edit and
a commit, not a redeploy.
