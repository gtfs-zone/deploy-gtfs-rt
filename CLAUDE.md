# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Terraform-based infrastructure deployment for a GTFS-RT (General Transit Feed Specification - Real Time) system. It deploys a complete microservices stack using the Docker provider on a single host, including authentication, monitoring, MQTT messaging, and APIs.

## Terraform Commands

All Terraform commands run from the `tf/` directory:

```bash
cd tf/

# Initialize providers and backend
terraform init

# Preview changes
terraform plan

# Deploy infrastructure
terraform apply

# Retrieve generated passwords
terraform output -raw postgres_admin_password

# Destroy everything (use with caution - volumes have prevent_destroy)
terraform destroy
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
| Messaging | NanoMQ (MQTT broker, TCP:8883 + WebSocket:8083) |
| Application | FastAPI (GTFS RT API) + OwnTrack Redis Bridge (MQTT→Redis) |
| Monitoring | Uptime Kuma |

### Database Setup Pattern
PostgreSQL uses a short-lived `postgres-init` container (runs once) to create per-service users and databases for dex and fastapi.

### Redis Database Allocation
- DB 0: oauth2-proxy sessions
- DB 1: FastAPI caching
- DB 2: Bridge pub/sub messages

### Monitoring

Uptime Kuma provides two Traefik routes:
- **Authenticated dashboard** (`uptime.<domain>`) — protected by oauth2-proxy forward auth
- **Public status page** (`status.<domain>`) — no auth, served by the same Uptime Kuma instance

The `tf-monitors/` directory contains a separate Terraform root for configuring Uptime Kuma via its API (using the `terraform-provider-uptimekuma` provider). Run it after the main stack is up:

```bash
cd tf-monitors/
terraform init
terraform apply
```

It manages: HTTP monitors (external + internal), TCP port monitors, Docker container monitors, a Telegram notification channel, and the public status page layout.

## Terraform File Organization

- `locals.tf` - Computed FQDNs and shared values
- `variables.tf` - All input variables (required and optional)
- `random.tf` - Auto-generated passwords/secrets for all services
- `networks.tf` - Docker networks
- `volumes.tf` - Named Docker volumes (all with `prevent_destroy = true`)
- `dns.tf` - Porkbun DNS records (root A record + CNAME subdomains)
- `compute_infra.tf` - Traefik, Redis, NanoMQ
- `compute_postgres.tf` - PostgreSQL + init container
- `compute_auth.tf` - Dex + oauth2-proxy
- `compute_api.tf` - FastAPI
- `compute_bridge.tf` - OwnTrack Redis bridge
- `compute_monitoring.tf` - Uptime Kuma (two Traefik routes: authenticated dashboard + public status page)
- `providers.tf` / `terraform.tf` - Provider config and version requirements
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

### Gitignored Files
- `tf/terraform.tfstate` and backups
- `tf/secrets.auto.tfvars`
- Generated Dex config (`dex/config.yaml`)

## Key Design Decisions

- All passwords are Terraform-managed (`random_password` resources) - never hardcoded
- Data volumes use `prevent_destroy = true` to protect against accidental data loss
- oauth2-proxy forward auth protects most services; status page is intentionally public
- External Traefik mode allows integration with a shared reverse proxy across multiple stacks
- Private images (`fastapi`, `bridge`) pulled from `git.kcfam.us`
