# Admin gating: what is left

One Keycloak group, `gtfs-admins`, is the single source of truth for admin
across the stack. Traccar is admin-only; cafe-car admins see and edit every feed
with full owner powers. `manage.rt.gtfs.zone` stays open to every realm account.

Shipped in `cafe-car@cbadf9b`, `music-student@c7e5341`, and the commit that
carries this file.

## Applied by hand to prod Keycloak

Realm import is create-only (see the trap in `CLAUDE.md`), so the
`gtfs-realm.json` edit does nothing to the running realm. These were applied
with `kcadm.sh` in the keycloak pod, and are already reflected in the file:

- group `gtfs-admins` created (id `0dba582f-e63e-4aa8-8973-001d36c8f370`)
- `groups` added as a **Default** client scope on the `traccar` client
- `groups` added as a **Default** client scope on the `oauth2-proxy` client

Verified: the realm's `groups` scope mapper is `full.path=false`, so the claim
value is the bare `gtfs-admins`, which is what `traccar.xml` matches on.

## Applied by hand to the prod Traccar database

Traccar users and the sign-up flag are DB state with no config key.

- `irvashing@gmail.com` disabled. `admin@gtfs.zone` (the cafe-car service
  account and break-glass local admin) and `maxkatzchristy@gmail.com` kept.
- `tc_servers.registration` was **true** and is now false. That form was an open
  bypass of the whole gate.

`maxkatzchristy@gmail.com` is still `administrator = f`; `openid.adminGroup`
promotes it on the next OIDC login.

## Still to do

### 1. Put yourself in `gtfs-admins`

**Blocking.** The group has no members. With `openid.allowGroup` live and an
empty group, every OIDC login to Traccar is refused (the local `admin` password
login and the master-realm admin still work, which is why `openid.force` is
deliberately unset).

```bash
ssh kcfam 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n gtfs exec \
  pod/keycloak-7674cb94f9-rxdtc -c keycloak -- /opt/keycloak/bin/kcadm.sh update \
  users/caedf9ea-6ec2-4b5d-a7e7-8c08a5be926d/groups/0dba582f-e63e-4aa8-8973-001d36c8f370 \
  -r gtfs -n'
```

`caedf9ea…` is `maxtkc` / maxkatzchristy@gmail.com. `maxtkc@mit.edu` is a
separate realm account and is **not** an admin; add it too if you want it.

### 2. Flush oauth2-proxy sessions after the sync

Existing sessions carry a token minted before the `groups` scope existed.

```bash
ssh kcfam 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n gtfs exec deploy/redis -- redis-cli -n 0 FLUSHDB'
```

### 3. Verify in prod

1. A `gtfs-admins` member logs into `traccar.gtfs.zone` via OpenID and lands as
   an administrator seeing every device.
2. A realm account not in the group is refused and creates no `tc_users` row.
3. `GET /api/server` returns 200. This is the canary: a mistyped
   `OPENID_CLIENT_SECRET` 500s here while the pod stays healthy.
4. The same non-admin still works normally at `manage.rt.gtfs.zone`.
5. Driver phones still post to `/osmand`, which is untouched and unauthenticated
   by design.
6. The "Transfer ownership to" control renders in the cafe-car members panel for
   an admin who is not the owner. Never eyeballed in a browser; the banner and
   the 200 say the controls are reachable, and the select may simply render
   empty when there is nobody to transfer to.

## Deferred

- **Declarative realm state.** Nothing reconciles `gtfs-realm.json` against the
  running realm. `keycloak-config-cli` as a sync Job is the obvious fix. Its own
  task.
- **`music-student/scripts/reset.sh` never ran end to end.** Host ports 8000 and
  8082 were bound by unrelated projects, so the `api` and `traccar` compose
  services could not start. Everything was verified with Traccar on 18082 and
  the admin app on 8001, which leaves the real browser OIDC redirect round trip,
  `reset.sh` as a whole, and the `api` service against the new `rt_api` role
  untested. Free the ports and run it.
- **uptime-kuma has no dev counterpart.** The one non-static prod service
  missing from compose.
- **Postgres major skew.** Dev is `postgres:16-alpine`, prod CNPG is 18.3. The
  role split surfaced no incompatibility, but surfacing exactly this was the
  point of the split.
- **`cafe-car/MBTA_GTFS.zip`** is an untracked stray, left alone.
