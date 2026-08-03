# Dex → Keycloak cutover

Why: Dex cannot link accounts. Each connector mints its own opaque `sub` and Dex
has no notion of one person with two connectors, so signing in with GitHub and
then with Google produced two unrelated accounts with separate feeds. Keycloak
brokers GitHub / Google / GitLab behind one realm user, and its stock
*first broker login* flow is already the "an account with this email exists —
link it?" prompt.

Two things move in the same cutover, because both are Dex clients today:

- **oauth2-proxy** (the admin app's ForwardAuth)
- **Traccar**, which is *not* behind oauth2-proxy — it does its own OIDC login.
  Miss it and its console login breaks silently while the pod stays healthy.

Dex keeps running on `dex.gtfs.zone` for one release with nothing pointed at it,
so the rollback is a revert rather than a redeploy.

## Before you start

- `id.gtfs.zone` is a new host. external-dns creates the record from the
  IngressRoute; the `*.gtfs.zone` wildcard in `gtfs-zone-tls` already covers it.
- `KEYCLOAK_ADMIN_PASSWORD` in `gtfs-app-secrets` is the master-realm bootstrap
  admin. The remap script in step 5 needs it.
- Realm import is **create-only**. Once the realm exists, editing
  `gtfs-realm.json` does nothing — later changes go through the admin console,
  or you drop the `keycloak` database and let it re-import.

## Sequence

1. **Push the manifests.** ArgoCD brings up Keycloak alongside Dex. Nothing is
   pointed at it yet by the *running* config until the rollout completes, so do
   this and then check before going further:

   ```bash
   kubectl -n gtfs rollout status deploy/keycloak
   kubectl -n gtfs logs deploy/keycloak -c render-realm      # "realm rendered"
   curl -s https://id.gtfs.zone/realms/gtfs/.well-known/openid-configuration | jq .issuer
   ```

   The issuer must read `https://id.gtfs.zone/realms/gtfs` exactly — it is baked
   into every token, and a mismatch fails validation everywhere at once.

   Then log in at `https://id.gtfs.zone/realms/gtfs/account` through each of the
   three providers and confirm the buttons render and the flow completes.

2. **Import the existing people into Keycloak first.** Every user who signs in
   *before* the remap creates a fresh Keycloak account, which is fine; what
   matters is that they exist with a **federated identity** so the remap can
   match them strongly. The cheapest way is to have each person log in once at
   `id.gtfs.zone` while the old stack is still serving.

3. **Dry-run the remap** (from cafe-car, against the production database):

   ```bash
   uv run scripts/remap_identities_to_keycloak.py \
       --keycloak-url https://id.gtfs.zone --realm gtfs \
       --admin-user admin --admin-password "$KC_ADMIN_PASSWORD"
   ```

   It refuses to write if any row is unmatched, or if two rows would map to one
   Keycloak subject. That second case means two cafe-car principals for one
   human: merge them at `manage.rt.gtfs.zone/account` **before** the cutover,
   because afterwards the second row is unreachable.

4. **Back up.** `kubectl -n gtfs exec postgres-1 -- pg_dump rt_api > rt_api.sql`.
   Step 5 rewrites identity rows in place.

5. **Run the remap for real** (`--apply`), then **flush oauth2-proxy's
   sessions** — every one of them references a Dex token:

   ```bash
   kubectl -n gtfs exec deploy/redis -- redis-cli -n 0 FLUSHDB
   ```

6. **Verify.** Sign in at `manage.rt.gtfs.zone`: you should land on the feeds you
   already owned, not an empty account. Open a feed's People panel. Then sign in
   to `traccar.gtfs.zone` via "Login with OpenID".

## Rollback

Revert the commit. Dex, its database and `DEX_*` secrets are all still in place,
so oauth2-proxy and Traccar go back to it. The one thing that does *not* revert
is the `identity` table if step 5 has run — restore `rt_api.sql`, or re-run the
remap in reverse from the Keycloak subjects.

## After it has held

Delete `gtfs/dex/`, its entry in `gtfs/kustomization.yaml`, the `dex` role and
`Database` in `postgres-cluster.yaml`, `postgres-dex.enc.yaml` and its line in
`secret-generator.yaml`, the `dex` IngressRoute, and the `DEX_*` keys in
`gtfs-app-secrets`.
