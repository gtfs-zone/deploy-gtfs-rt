## v0.1.2 (2026-10-01)

### BREAKING CHANGE

- the Terraform deployment is gone. Deploying this stack now
requires a k3s cluster and ArgoCD; see README Steps 1-5.

### Feat

- **ingress**: compress data.gtfs.zone responses
- **cape-flier**: worker processes and memory limit for catalog sites
- **sites**: cape-flier bucket key and Gatus token
- **sites**: serve sites.gtfs.zone from Garage, built by cape-flier
- **list**: proxy feed pages from Garage and monitor them
- **gatus**: check data.gtfs.zone/feeds.json hourly
- **geometry-car**: enable Dagster run monitoring
- **gatus**: monitor list, data, dagster and garage; catalog publish heartbeat
- **sites**: deploy globe-of-contents at list.gtfs.zone
- **geometry-car**: set the Mobility Database refresh token
- **geometry-car**: deploy the catalog pipeline
- **cutover**: swap manage.rt.gtfs.zone to yard-master
- **sites**: stand up yard-master on a temporary hostname
- **garage**: object storage for uploaded GTFS zips
- **monitoring**: telegram alerts on gatus
- **monitoring**: replace Uptime Kuma with Gatus
- **auth**: gate Traccar on the gtfs-admins Keycloak group
- **keycloak**: land id.gtfs.zone in the gtfs realm, not master
- **keycloak**: let realm accounts into the gtfs admin console
- **argocd**: sign in through Keycloak with group-based RBAC
- **rt-api**: allow all origins on the public GTFS-RT API
- **keycloak**: let the account page read linked providers
- **gtfs**: bump cafe-car to 94382d5
- **gtfs**: let viz read the catalog, and make logout actually log out
- **gtfs**: repoint oauth2-proxy and Traccar at Keycloak
- **gtfs**: stand Keycloak up alongside Dex
- **gtfs**: deploy trip-updogger so trip updates work again
- bump app images to latest main (cafe-car, hell-gate, poser, foamer)
- bump cafe-car and sqladmin vendored assets outside
- **k3s**: Phase 9 — decommission the Docker stack, rewrite the docs
- **k3s**: Phases 5a/6a/7 — Traccar ingest layer + ingress
- **k3s**: Phase 6 — gtfs application layer
- **k3s**: Phase 4 — infra secrets layer (SOPS Porkbun creds)
- **k3s**: Phase 5 — gtfs stateful layer (CNPG Postgres + Redis)
- **k3s**: Phase 3 — infra layer ArgoCD Applications
- **k3s**: Phase 2 — bootstrap ArgoCD + KSOPS CMP sidecar + app-of-apps
- support faster mqtt auth
- add celery limits
- deploy celery worker for async static gtfs fetching
- add trip-updogger
- add google and gitlab login connectors to dex

### Fix

- **ingress**: constant CORS origin on data.gtfs.zone
- **garage**: make geometry-car's key owner of data.gtfs.zone so it can set CORS
- **geometry-car**: give the daemon liveness check a 15s timeout
- **geometry-car**: run the migrate hook PostSync
- **geometry-car**: write dagster.yaml inside the migrate hook
- **hell-gate-bridge**: point INGEST_VEHICLE_ID at Tracker.id
- **dns**: keep gtfs.zone's apex A record out of external-dns
- **dns**: pin the apex A record's TTL so the webhook can edit it
- **dns**: unblock the zone, and retire manage-old.rt.gtfs.zone
- **garage**: use tcpSocket probes instead of /health
- **celery**: set REDIS_URL on both celery Deployments
- **keycloak**: drop the PKCE requirement from the argocd client
- **longhorn**: default new nodes onto /srv instead of /var
- bump hgb
- hgb bump
- remove Dex now the Keycloak cutover has held
- bumps and add check-bumps script
- bump for wherebus
- **keycloak**: drop the comment keys that fail realm import
- **keycloak**: trust the brokers' verified email
- **keycloak**: tell tokens which broker the session came through
- bump trip-updogger
- **k3s**: correct ignoreDifferences for Longhorn CRDs; fix docs
- **traefik**: bump chart 35.2.0 -> 38.0.2 for errors middleware {url} placeholder
- **auth**: route /oauth2/ past ForwardAuth on manage-rt and uptime
- **traccar**: correct the OIDC client-secret env var name
- **k3s**: stop dex crashing on a template call inside a comment
- **k3s**: redis fsGroup; correct gtfs-zone-tls SANs
- **k3s**: unblock Phase 8 — Longhorn hook, external-dns webhook, DNS-01 RBAC
- **tf**: correct celery module path to schedule_foamer.celery_app
- explicitly expose nanomq
- run migrations the new way
- fix updogger db
- use http for mqtt acl
- pass email and user claims in jwt token
- update uptime kuma monitors

### Refactor

- rename cluster resources to the new service names
- apply copier (#58)
- rename api to cafe-car and update docs
- rm prometheus
- avoid using fastapi for rt-api

## v0.1.1 (2026-03-03)
