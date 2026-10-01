# Architecture

The real-time data flow, the data model and the auth flow are drawn in
[README.md](../README.md#system-diagrams).

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
- `gtfs/`: the application stack (Kustomize): Postgres (CNPG), Redis, Garage,
  Keycloak, oauth2-proxy (plus `oauth2-proxy-admin`), rt-api, celery, Gatus,
  Traccar, rt-traccar-receiver, rt-pollers, feed-catalog (`feed-catalog/` for
  the three Dagster Deployments and their instance config,
  `feed-catalog-migrate.yaml` for its PreSync hook), IngressRoutes, and
  SOPS-encrypted `secrets/*.enc.yaml`. feed-catalog's CI writes its image
  digest into `gtfs/kustomization.yaml`'s `images:` block.
- `sites/`: the nginx-served sites (Kustomize, no secrets):
  `manage.rt.gtfs.zone` (rt-manager) and `list.gtfs.zone`
  (feed-list), plus `pages-dns.yaml`, the DNSEndpoint CNAMEs for
  `edit.gtfs.zone` and `viz.rt.gtfs.zone`, which GitHub Pages serves. The
  `gtfs.zone` apex is on Pages too, with its A/AAAA records kept by hand at
  Porkbun. Each nginx site is an nginx image
  built by its own repo's CI and pushed to ghcr.io; that CI runs
  `kustomize edit set image` here and commits, so `sites/kustomization.yaml` is
  the deploy record. Rollback = point the image back at an earlier digest.
  Their IngressRoutes deliberately live in the `gtfs` namespace, where the TLS
  Secrets are.
- `.sops.yaml`: age recipient + encryption rules. The private key (`age.key`)
  is gitignored.

Namespaces: `gtfs`, `sites`, `argocd`, `cert-manager`, `traefik`,
`external-dns`, `cnpg-system`, `longhorn-system`.

## Edge

```
Internet :80/:443
   └─ home-docker Traefik (Docker, still owns 80/443)
        ├─ *.kcfam.us -> terminated locally
        └─ *.gtfs.zone -> TCP SNI passthrough -> 172.18.0.1:8443
                                                   │
   k3s single node ─────────────────────────────────┘
     Traefik (Helm), websecure entrypoint on host :8443 via ServiceLB
       └─ IngressRoute: rt, manage.rt, id, auth, status, traccar,
          data + sites (Garage s3_web :3902), dagster (oauth2-proxy-admin),
          list (from sites/)
          (+ argocd, in the argocd namespace)
     cert-manager (Porkbun DNS-01), external-dns, Longhorn, CNPG, ArgoCD
```

TLS for `*.gtfs.zone` is owned end to end by cert-manager in the cluster; the
edge only passes bytes through. `gtfs.zone`, `edit.gtfs.zone` and
`viz.rt.gtfs.zone` are on GitHub Pages and never reach this machine.

## Ingest

**MQTT** is permanently retired: NanoMQ and OwnTracks are gone and are not
coming back. Positions arrive over HTTP only; Redis is still the seam.

`rt-delay-estimator` is **not** retired; it came back in a different shape. It is now
a Redis->Redis worker with no broker: it sweeps `vehicle:*`, loads the trip's
scheduled `stop_times` from Postgres, and writes `trip_update:*`. It is what turns
a raw position into a *delay*, so without it a Traccar-sourced feed serves
positions and an **empty `trip_updates.pb`**.

## Service map

| Layer | What runs |
|---|---|
| Edge | Traefik (Helm), `websecure` on host :8443; `IngressRoute`/`Middleware` CRDs |
| TLS / DNS | cert-manager + Porkbun DNS-01 webhook; external-dns (Porkbun webhook) |
| Storage | Longhorn (default StorageClass, 1 replica) |
| Object storage | Garage (single-node StatefulSet; `garage-init` PostSync Job applies the layout, buckets and keys). Three buckets, each with its own key: `gtfs-feeds` is private, S3 API cluster-internal only (uploaded zips); `data.gtfs.zone` and `sites.gtfs.zone` are public, served read-only over HTTP by Garage's `s3_web` endpoint at their own hostnames (feed-catalog's artifacts, timetable-sites' timetable sites; `sites` goes through a Traefik `compress` middleware) |
| Database | CloudNativePG `Cluster` `postgres` -> `rt_api`, `keycloak`, `traccar`, `feed_catalog` databases |
| Cache | Redis (DB 0 oauth2-proxy, 1 rt-api + rt-traccar-receiver, 2 oauth2-proxy-admin, 3 celery broker, 4 celery result) |
| Auth | Keycloak (OIDC, `id.gtfs.zone`, brokers GitHub/Google/GitLab) + two oauth2-proxy instances, each ForwardAuth via its own pair of Middlewares: `oauth2-proxy` (`oauth2-errors` + `oauth2-proxy`) admits any realm account and fronts `manage.rt`; `oauth2-proxy-admin` (`oauth2-admin-errors` + `oauth2-admin`) requires the `gtfs-admins` group and fronts `dagster`. Traccar is a separate Keycloak client with its own login, gated on the same group |
| Application | rt-api (`gtfs-api` :8000 public, `gtfs-manager` :8001 protected), celery worker + beat |
| Ingest | Traccar, rt-traccar-receiver, rt-delay-estimator, rt-pollers ×2 |
| Catalog | feed-catalog: Dagster webserver (`dagster.gtfs.zone`), daemon and code server, Postgres run storage, publishing to the `data.gtfs.zone` bucket. timetable-sites is a second code location in the same instance (`timetable-sites-code`), publishing to the `sites.gtfs.zone` bucket daily at 11:00 UTC |
| Sites | nginx images in `sites/`, built by each repo's CI. The four map apps (edit, viz, manage.rt, list) share one app shell from `gtfs-zone-web-common` |
| Monitoring | Gatus, config-as-code in `gtfs/gatus/config.yaml`, public page at `status.gtfs.zone`, Telegram alerts |
