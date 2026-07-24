# deploy-gtfs-rt

**GTFS.Zone** is a "public option" for transit operators to publish real-time
GTFS feeds. The goal is to make it as simple, lightweight, and inexpensive as
possible — a small agency with minimal technical resources should be able to
get a live feed running in an afternoon.

Operators who don't want to self-host can use an already-running instance
without touching any of this. This repo is for those who want to run their own.

### How it fits together

The stack is built from these open-source projects:

| Project | Role |
|---------|------|
| [cafe-car](https://git.kcfam.us/gtfs.zone/cafe-car) | Core API — serves GTFS-RT feeds and handles admin |
| [vehicle-poser](https://git.kcfam.us/gtfs.zone/vehicle-poser) | Ingests vehicle positions from OwnTracks via MQTT → Redis |
| [trip-updogger](https://git.kcfam.us/gtfs.zone/trip-updogger) | Computes trip update delays from OwnTracks locations via MQTT → Redis |
| [schedule-foamer](https://git.kcfam.us/gtfs.zone/schedule-foamer) | Celery worker + beat scheduler for async static GTFS fetching |
| [railroad-club](https://git.kcfam.us/gtfs.zone/railroad-club) | Shared SQLAlchemy models and Alembic migrations |
| [music-student](https://git.kcfam.us/gtfs.zone/music-student) | Docker Compose stack for local development and testing |
| [landing-zone](https://git.kcfam.us/gtfs.zone/landing-zone) | Static homepage at gtfs.zone |

This repo provides the Terraform deployment that wires them together with supporting infrastructure.

```mermaid
flowchart LR
    classDef repo fill:#dbeafe,stroke:#3b82f6,color:#1e3a5f
    classDef dir fill:#fef9c3,stroke:#d97706,color:#5c3d00
    classDef tf fill:#dcfce7,stroke:#16a34a,color:#14532d

    traefik_dir["`**traefik/**`"]:::dir
    dex_dir["`**dex/**`"]:::dir
    nanomq_dir["`**nanomq/**`"]:::dir
    tf[["`**tf/**<br>OpenTofu root`"]]:::tf
    tfm[["`**tf-monitors/**<br>Uptime Kuma config`"]]:::tf
    traefik_dir & dex_dir & nanomq_dir -->|"local build"| tf
    tf -.-|"runs after"| tfm

    subgraph registry["Container Registry"]
        cc(["**cafe-car**<br>GTFS-RT API + admin"]):::repo
        vp(["**vehicle-poser**<br>relay vehicle position"]):::repo
        tu(["**trip-updogger**<br>trip delay engine"]):::repo
        sf(["**schedule-foamer**<br>GTFS Static Downloader"]):::repo
    end

    rc(["**railroad-club**<br>SQLAlchemy models + migrations"]):::repo
    ms(["**music-student**<br>local dev Compose"]):::repo

    rc -->|"models + migrations"| cc
    rc -->|"models"| tu
    rc -->|"models"| sf

    cc -->|"container image"| tf
    vp -->|"container image"| tf
    tu -->|"container image"| tf
    sf -->|"container image"| tf

    tf -.-|"mirrors for local dev"| ms
```

**Issues & roadmap:** [issue tracker](https://git.kcfam.us/gtfs.zone/deploy-gtfs-rt/issues) · [project kanban](https://git.kcfam.us/gtfs.zone/-/projects/3)

---

## What you get

| URL | Service |
|-----|---------|
| `rt.<domain>` | Public GTFS-RT feed API |
| `manage.rt.<domain>` | Admin UI (auth-gated) |
| `auth.<domain>` | oauth2-proxy sign-in |
| `dex.<domain>` | Dex OIDC provider |
| `mqtt.<domain>:443` | MQTT (TLS, SNI-routed) |
| `ws.mqtt.<domain>` | MQTT over WebSocket |
| `uptime.<domain>` | Uptime Kuma dashboard (auth-gated) |
| `status.<domain>` | Public status page |


## System Diagrams

### Real-time data flow

A position update travels from a driver's phone to a GTFS-RT consumer in under a second.

```mermaid
sequenceDiagram
    actor driver as Driver<br>(OwnTracks app)
    actor operator as Operator
    participant mgr as cafe-car admin
    participant NanoMQ@{ "type": "queue" }
    participant vp as vehicle-poser
    participant tu as trip-updogger
    participant Redis@{ "type": "database" }
    participant postgres@{ "type": "database" }
    participant pub as cafe-car public
    actor consumer as GTFS Consumer<br>(Google Maps, etc.)

    Note over driver,NanoMQ: MQTT connection & auth
    driver->>NanoMQ: MQTT CONNECT (TLS :443, SNI)
    NanoMQ->>pub: POST /mqtt/auth
    pub-->>NanoMQ: 200 OK

    Note over driver,Redis: Real-time position update
    driver->>NanoMQ: PUBLISH owntracks/username/device
    NanoMQ->>vp: subscribe
    vp->>Redis: HSET vehicle_positions
    NanoMQ->>tu: subscribe
    tu->>Redis: HSET trip_delays

    Note over operator,mgr: Admin
    operator->>mgr: POST /alerts
    mgr->>postgres: INSERT service_alert
    postgres-->>mgr: ok
    mgr-->>operator: 201 Created

    Note over pub,consumer: Vehicle Positions
    consumer->>pub: GET /rt/vehicle-positions.pb
    pub->>Redis: HGETALL vehicle_positions
    Redis-->>pub: positions
    pub-->>consumer: VehiclePosition FeedMessage

    Note over pub,consumer: Trip Updates
    consumer->>pub: GET /rt/trip-updates.pb
    pub->>Redis: HGETALL trip_delays
    Redis-->>pub: delays
    pub-->>consumer: TripUpdate FeedMessage

    Note over pub,consumer: Service Alerts
    consumer->>pub: GET /rt/service-alerts.pb
    pub->>postgres: SELECT service_alerts
    postgres-->>pub: alerts
    pub-->>consumer: Alert FeedMessage
```

### System context

External actors and systems the stack integrates with.

```mermaid
flowchart LR
    driver(["Driver<br>(OwnTracks app)"])
    operator(["Transit Operator"])
    consumer(["GTFS Consumer<br>(Google Maps, etc.)"])

    owntracks["OwnTracks<br>Free & open source location app"]
    oauth["OAuth Provider<br>GitHub / GitLab / Google"]
    porkbun["Porkbun DNS<br>TLS via DNS-01 challenge"]
    gtfs_src["Static GTFS Source<br>Agency schedule ZIP files"]

    stack["GTFS.Zone Stack"]

    driver -->|"drives with"| owntracks
    owntracks -->|"MQTT/TLS :443"| stack
    operator -->|"admin UI"| stack
    stack -->|"GTFS-RT protobuf"| consumer
    stack -->|"DNS + cert management"| porkbun
    oauth -->|"OIDC tokens"| stack
    stack -->|"fetch schedule"| gtfs_src
```

### Core data model

All models defined in [railroad-club](https://git.kcfam.us/gtfs.zone/railroad-club) and shared across services.

```mermaid
erDiagram
    USER {
        int id PK
        string provider
        string provider_subject
        string email
        string display_name
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

    USER ||--o{ FEED : owns
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

Subdomain routing from the internet through Traefik to each service, with data-layer connections.

```mermaid
stateDiagram-v2
    Internet : Internet
    tr : Traefik<br>TLS termination · Let's Encrypt via Porkbun DNS
    nm : NanoMQ<br>MQTT broker · TLS 443 via SNI · WebSocket
    uk : Uptime Kuma

    state "Auth" as auth {
        op : oauth2-proxy<br>Forward auth middleware
        dx : Dex<br>OIDC provider
    }

    state "cafe-car" as application {
        cp : gtfs-api<br>public GTFS-RT feed
        ca : gtfs-manager<br>admin interface
    }

    state "Workers" as workers {
        vp : vehicle-poser
        tu : trip-updogger
        sf : schedule-foamer<br>Celery worker + beat
    }

    [*] --> Internet
    Internet --> tr

    tr --> cp : rt.&ltdomain&gt
    tr --> op : manage.rt / auth.&ltdomain&gt
    tr --> dx : dex.&ltdomain&gt
    tr --> nm : mqtt.&ltdomain&gt 443 · ws.mqtt.&ltdomain&gt
    tr --> uk : status.&ltdomain&gt (public)

    op --> ca : manage.rt.&ltdomain&gt (authed)
    op --> uk : uptime.&ltdomain&gt (authed)
    op --> dx : OIDC token check

    nm --> cp : /mqtt/auth
    nm --> vp : position events
    nm --> tu : position events
```

### Real-time data pipeline

MQTT message from a driver's phone arriving as a GTFS-RT protobuf response.

```mermaid
flowchart TD
    driver(["Driver<br>OwnTracks app"])

    subgraph mqtt["NanoMQ · MQTT broker"]
        nanomq["TLS :443 (SNI)<br>WebSocket on ws.mqtt.&ltdomain&gt"]
    end

    subgraph ingestion["Ingestion workers"]
        vp["vehicle-poser"]
        tu["trip-updogger"]
    end

    subgraph store["Redis DB 1"]
        positions[["vehicle_positions"]]
        delays[["trip_delays"]]
    end

    subgraph api["cafe-car · gtfs-api"]
        cafe_pub["public GTFS-RT feed"]
    end

    consumer(["GTFS Consumer<br>Google Maps, etc."])

    driver -->|"PUBLISH owntracks/user/device"| nanomq
    nanomq --> vp & tu
    vp -->|"HSET"| positions
    tu -->|"HSET"| delays
    positions & delays -->|"HGETALL"| cafe_pub
    cafe_pub -->|"VehiclePosition · TripUpdate"| consumer
```

### Auth flow

How an operator reaches a protected service via Dex and oauth2-proxy.

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
        [*] --> Dex
        Dex --> OAuthProvider: redirect
        OAuthProvider --> Dex: auth code
        Dex --> [*]: ID token → session
    }

    Requesting --> Serving: authenticated

    state Serving {
        [*] --> Protected: cafe-car admin
        Protected --> [*]: 200 OK
    }

    Serving --> [*]
```


## Development

```bash
# Install git hooks (required once per clone)
pre-commit install
```

## Prerequisites

- **A server** running [Docker](https://docs.docker.com/engine/install/) with a public IP (any VPS works)
- **A domain on [Porkbun](https://porkbun.com/)** with API access enabled
- **[OpenTofu](https://opentofu.org/docs/intro/install/)** installed locally
- **At least one OAuth provider** (GitHub, GitLab, or Google) for user login
- **Credentials** for the private registry at `git.kcfam.us` (to pull `cafe-car`, `vehicle-poser`, and `trip-updogger` images)

## Step 1 — Domain and DNS API

1. Buy a domain at [porkbun.com](https://porkbun.com).
2. In your Porkbun account go to **API** → enable API access for the domain.
3. Generate an API key pair (`pk1_...` / `sk1_...`) — you'll need both.

## Step 2 — OAuth app

Create an OAuth app with at least one provider. Use `https://dex.<your-domain>/callback` as the authorization callback URL.

- **GitHub**: Settings → Developer settings → OAuth Apps → New OAuth App
- **GitLab**: User Settings → Applications
- **Google**: Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client ID (Web application)

## Step 3 — Configure secrets

```bash
cd tf/
cp secrets.auto.tfvars.example secrets.auto.tfvars
```

Edit `secrets.auto.tfvars` and fill in at minimum:

```hcl
domain    = "yourdomain.com"
server_ip = "1.2.3.4"   # your server's public IP

# Porkbun DNS API
porkbun_api_key        = "pk1_..."
porkbun_secret_api_key = "sk1_..."

# At least one OAuth provider
github_oauth = {
  client_id     = "..."
  client_secret = "..."
}

# Private registry (for cafe-car, vehicle-poser, and trip-updogger images)
registry_username = "..."
registry_password = "..."
```

If your Docker host is remote, also set:

```hcl
docker_host = "ssh://myserver"
```

## Step 4 — Deploy

```bash
cd tf/
tofu init
tofu apply
```

Terraform will:
- Create DNS records on Porkbun
- Build local images for Traefik, Dex, and NanoMQ from this repo
- Pull `cafe-car`, `vehicle-poser`, and `trip-updogger` from the private registry
- Start all containers; Traefik obtains TLS certificates automatically via DNS challenge

Retrieve auto-generated passwords if needed:

```bash
tofu output -raw postgres_admin_password
tofu output -raw uptime_kuma_password
```

## Step 5 — Configure monitors

After the main stack is running, set up Uptime Kuma monitors:

```bash
cd tf-monitors/
cp secrets.auto.tfvars.example secrets.auto.tfvars
```

Fill in `tf-monitors/secrets.auto.tfvars`:

```hcl
domain               = "yourdomain.com"   # must match tf/
uptime_kuma_password = "..."              # from: tofu -chdir=../tf output -raw uptime_kuma_password
telegram_bot_token   = "..."             # optional, for alert notifications
telegram_chat_id     = "..."
```

```bash
tofu init
tofu apply
```

## Updating

To redeploy after an image update:

```bash
cd tf/
tofu apply -replace=docker_container.rt_api_public -replace=docker_container.rt_api_admin
```

To rebuild a locally-built image (Traefik/Dex/NanoMQ), edit any file in its
source directory — Terraform detects the change and rebuilds on the next
`apply`.

## Sharing a Docker host

Set `name_prefix = "gtfs"` in `secrets.auto.tfvars` to namespace all
containers, volumes, and networks. To reuse an existing Traefik instance:

```hcl
use_external_traefik     = true
external_traefik_network = "proxy-tier"
traefik_cert_resolver    = "letsencrypt"
```
