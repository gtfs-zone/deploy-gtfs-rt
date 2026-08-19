# Admin gating: what is left

One Keycloak group, `gtfs-admins`, is the single source of truth for admin
across the stack. Traccar is admin-only; cafe-car admins see and edit every feed
with full owner powers. `manage.rt.gtfs.zone` stays open to every realm account.

Shipped and live: `cafe-car@cbadf9b`, `music-student@c7e5341`,
`deploy-gtfs-rt@d7fa288` (the gate) and `@51c61a2` (the `cafe-car:cbadf9b` pin).
ArgoCD synced `gtfs` to `51c61a2`, Synced/Healthy.

## Applied by hand to prod Keycloak

Realm import is create-only (see the trap in `CLAUDE.md`), so the
`gtfs-realm.json` edit does nothing to the running realm. These were applied
with `kcadm.sh` in the keycloak pod, and are already reflected in the file:

- group `gtfs-admins` created (id `0dba582f-e63e-4aa8-8973-001d36c8f370`), with
  `maxtkc` / maxkatzchristy@gmail.com (id
  `caedf9ea-6ec2-4b5d-a7e7-8c08a5be926d`) as its only member. `maxtkc@mit.edu`
  is a separate realm account and is deliberately **not** an admin.
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

## Verified in prod after the sync

- ArgoCD `gtfs` Synced/Healthy at `51c61a2`; `gtfs-api`, `gtfs-manager`,
  `keycloak`, `traccar` and `oauth2-proxy` all rolled, `gtfs-migrate` completed.
- oauth2-proxy crash-looped 3x on OIDC discovery 503 purely because Keycloak was
  restarting at the same moment, then came up clean. Expected race, not a bug.
- Redis DB0 (oauth2-proxy sessions) flushed, 3 keys to 0. db1/db3/db4 untouched.
- Traccar `GET /api/server` 200 with `registration:false`, `openIdEnabled:true`,
  `openIdForce:false`. Also 200 through the edge at `traccar.gtfs.zone`.
- Keycloak `generate-example-access-token` for the **traccar** client as
  `maxtkc` emits `groups: [argocd-admins, gtfs-admins, keycloak-admins]` as bare
  names, which is what `openid.allowGroup` matches. The same call for
  `irvashing@gmail.com` emits **no** `groups` claim, so that account is refused
  at the callback and creates no `tc_users` row.
- The **oauth2-proxy** client emits the same claim, with `sub` as the UUID, which
  is what cafe-car keys an Identity on.
- Ingest untouched: Traccar `:5055/osmand` answers 400 for an unknown device id,
  not 401/403.
- `rt.gtfs.zone/health` and `/docs` 200; `manage.rt.gtfs.zone` 401 with the
  sign-in body, which is correct per `CLAUDE.md`.

## Still to do: browser only

The token evaluation above proves both halves separately. The real OIDC redirect
round trip has still never been walked end to end, in prod or in dev.

1. Log into `traccar.gtfs.zone` via OpenID as a `gtfs-admins` member and confirm
   you land as an administrator seeing every device. On that first login
   `openid.adminGroup` should flip `tc_users.administrator` to `t` for
   maxkatzchristy@gmail.com, which is still `f`:
   ```bash
   ssh kcfam 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n gtfs exec postgres-1 -c postgres -- psql -d traccar -c "SELECT id, email, administrator, disabled FROM tc_users ORDER BY id;"'
   ```
2. Confirm a realm account outside the group is refused and creates no new row
   in that same table.
3. Confirm the "Transfer ownership to" control renders in the cafe-car members
   panel for an admin who is not the owner. The banner and the 200 say the
   controls are reachable; the select may simply render empty when there is
   nobody to transfer to.

## Device visibility, found during the browser check

The first real OIDC admin login worked (admin console reachable,
`tc_users.administrator` flipped to `t`) but showed **zero devices**. Being a
Traccar administrator does not bypass the `tc_user_device` scoping; all 7
devices were linked only to `admin@gtfs.zone`, cafe-car's service account.

Fixed with a device group rather than per-device shares:

- Traccar group **All Vehicles** (id 1) created; all 7 devices moved into it;
  the group linked to `maxtkc` (user 2). `admin@gtfs.zone` kept its 7 direct
  links, so cafe-car's provisioning is undisturbed.
- `cafe-car@0729883` puts every device it provisions into that group
  (`settings.traccar_device_group`), so new devices are visible to every admin
  already linked to the group. Deployed as `deploy-gtfs-rt@20d84ae`.

Still manual: linking the group to each *new* admin, once. A device created by
hand in the Traccar UI gets no group and stays invisible.

**Not yet verified live:** that a newly provisioned device actually lands in the
group. Six unit tests cover it against `httpx.MockTransport`; the next real
tracker provision is the end-to-end proof.

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
- **`keycloak-admins` and `argocd-admins` are now redundant-ish.** All three
  groups have exactly one member, `maxtkc`. Not a problem, but if a second admin
  ever appears, decide whether `gtfs-admins` subsumes them.
