# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Terraform-based infrastructure deployment for a GTFS-RT (General Transit Feed Specification - Real Time) system. It deploys a complete microservices stack using the Docker provider on a single host, including authentication, monitoring, MQTT messaging, and APIs.

## Terraform Commands

All OpenTofu commands run from the `tf/` directory:

```bash
cd tf/

# Initialize providers and backend
tofu init

# Preview changes
tofu plan

# Deploy infrastructure
tofu apply

# Retrieve generated passwords
tofu output -raw postgres_admin_password

# Destroy everything (use with caution - volumes have prevent_destroy)
tofu destroy
```

## Architecture

### Networks
- **proxy-tier**: External-facing network (Traefik + publicly exposed services)
- **internal**: Internal-only network (databases, monitoring, message brokers)

### Service Stack

| Layer | Services |
|-------|----------|
| Reverse Proxy | Traefik v3.6 (Let's Encrypt via Porkbun DNS challenge) |
| Auth | Dex (OIDC provider) + oauth2-proxy (forward auth middleware) |
| Databases | PostgreSQL (multi-tenant) + Redis (sessions/cache/pub-sub) |
| Messaging | NanoMQ (MQTT broker, TLS on :443 via SNI + WebSocket on :443) |
| Application | cafe-car (GTFS RT API) + vehicle-poser (MQTT→Redis bridge) + trip-updogger (trip delays) + schedule-foamer (Celery worker + beat) |
| Monitoring | Uptime Kuma |

### Related Repositories
- **[railroad-club](https://git.kcfam.us/gtfs.zone/railroad-club)** — shared SQLAlchemy models and Alembic migrations used by cafe-car and other services
- **[music-student](https://git.kcfam.us/gtfs.zone/music-student)** — Docker Compose stack for local development and testing

### Init Container Pattern
PostgreSQL uses a short-lived `postgres-init` container (runs once) to create per-service users and databases for dex and rt-api. rt-api similarly uses a short-lived `gtfs-migrate` container to run Alembic database migrations before the API starts.

### Redis Database Allocation
- DB 0: oauth2-proxy sessions
- DB 1: rt-api + Bridge (shared vehicle position data)
- DB 3: Celery broker (schedule-foamer tasks)
- DB 4: Celery result backend

### cafe-car Dual Container
The cafe-car image runs as two separate containers:
- **`gtfs-api`** (public, port 8000) — unauthenticated GTFS-RT feed at `rt.<domain>`
- **`gtfs-manager`** (admin, port 8001) — protected by oauth2-proxy forward auth at `manage.rt.<domain>`

NanoMQ delegates MQTT authentication to `http://gtfs-api:8000/mqtt/auth`.

### Adding Auth to a New Service
To protect a new Traefik route with oauth2-proxy, add these two middlewares to its router labels:
```
traefik.http.routers.<name>.middlewares = "${local.prefix}oauth2-errors@docker,${local.prefix}oauth2-proxy@docker"
```

### Monitoring

Uptime Kuma provides two Traefik routes:
- **Authenticated dashboard** (`uptime.<domain>`) — protected by oauth2-proxy forward auth
- **Public status page** (`status.<domain>`) — no auth, served by the same Uptime Kuma instance

The `tf-monitors/` directory contains a separate OpenTofu root for configuring Uptime Kuma via its API (using the `terraform-provider-uptimekuma` provider). Run it after the main stack is up:

```bash
cd tf-monitors/
tofu init
tofu apply
```

It manages: HTTP monitors (external + internal), TCP port monitors, Docker container monitors, a Telegram notification channel, and the public status page layout.

## Terraform File Organization

- `images.tf` - Local Docker image builds for Traefik, Dex, and NanoMQ (from repo subdirectories; rebuilt automatically when source files change)
- `locals.tf` - Computed FQDNs and shared values
- `variables.tf` - All input variables (required and optional)
- `random.tf` - Auto-generated passwords/secrets for all services
- `networks.tf` - Docker networks
- `volumes.tf` - Named Docker volumes (all with `prevent_destroy = true`)
- `dns.tf` - Porkbun DNS records (root A record + CNAME subdomains)
- `compute_infra.tf` - Traefik, Redis, NanoMQ
- `compute_postgres.tf` - PostgreSQL + init container
- `compute_auth.tf` - Dex + oauth2-proxy
- `compute_api.tf` - rt-api
- `compute_celery.tf` - schedule-foamer Celery worker + beat scheduler
- `compute_bridge.tf` - OwnTrack Redis bridge
- `compute_monitoring.tf` - Uptime Kuma (two Traefik routes: authenticated dashboard + public status page)
- `providers.tf` / `terraform.tf` - Provider config and OpenTofu version requirements
- `backend.tf` - Local state backend
- `outputs.tf` - Sensitive password outputs

## Configuration

### Required Setup
Copy `tf/secrets.auto.tfvars.example` to `tf/secrets.auto.tfvars` and populate:
- `domain` - Base domain (e.g., `"gtfs.example.com"`)
- `server_ip` - Public IP for DNS A record
- `porkbun_api_key` / `porkbun_secret_api_key` - Porkbun DNS credentials

### Optional Configuration
- `docker_host` - Remote Docker URI (null = local socket)
- `name_prefix` - Prefix all resource names
- `registry_username` / `registry_password` - Private registry at `git.kcfam.us`
- `use_external_traefik` / `external_traefik_network` - Skip internal Traefik deployment
- Per-service subdomain overrides and image version pins

### Adding Variables
Whenever a new variable is added to `variables.tf`, it **must** also be added to `tf/secrets.auto.tfvars.example` (commented out with its default shown if optional, or with a placeholder value if required).

### Gitignored Files
- `tf/terraform.tfstate` and backups (OpenTofu state files)
- `tf/secrets.auto.tfvars`
- Generated Dex config (`dex/config.yaml`)

## Key Design Decisions

- All passwords are Terraform-managed (`random_password` resources) - never hardcoded
- Data volumes use `prevent_destroy = true` to protect against accidental data loss
- oauth2-proxy forward auth protects most services; status page is intentionally public
- External Traefik mode allows integration with a shared reverse proxy across multiple stacks
- Private images (`cafe-car`, `vehicle-poser`, `trip-updogger`, `schedule-foamer`) pulled from `git.kcfam.us`
- Models and migrations live in `railroad-club`; `gtfs-migrate` init container applies them on startup
- `music-student` provides a Docker Compose equivalent for local development
- Traefik, Dex, and NanoMQ are built locally via `images.tf` from the repo's `traefik/`, `dex/`, and `nanomq/` subdirectories; Terraform rebuilds them when source files change
