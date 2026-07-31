# First-run checklist — the steps that need a browser and a phone

Everything that could be automated has been. What is left needs a human with a
browser and an Android/iOS device. Work top to bottom; each step says how to
tell it actually worked, because several of these fail **silently**.

Prereq for any `kubectl` in here: `ssh -N -L 6443:127.0.0.1:6443 kcfam`.

Already done for you, do **not** repeat:

- Traccar admin account created (`admin@gtfs.zone`, id 1, `administrator: true`)
  using the `TRACCAR_ADMIN_*` values already in `gtfs-app-secrets`.
- Traccar registration enabled (`registration = t` in `tc_servers`).
- Alembic migrations applied; `rt_api`, `dex`, `traccar` databases exist.

---

## 1. First admin login — creates the owner row

**Go to:** <https://manage.rt.gtfs.zone>

You should get oauth2-proxy's **Sign In** page with a Dex button. Click through
to your OAuth provider and back.

> The page arrives with HTTP status **401**. That is correct and expected —
> Traefik's `errors` middleware serves the sign-in body while preserving the
> original status code. Only treat it as broken if the *body* isn't the sign-in
> page.

**Why it matters:** the first successful login creates the `User` row that
`Feed.owner_id` points at. Feed creation fails without it.

**Verify:**
```bash
kubectl exec -n gtfs postgres-1 -c postgres -- \
  psql -U postgres -d rt_api -tAc "select id, email from users order by id limit 5"
```
Expect at least one row.

---

## 2. Log in to Traccar with the admin account

**Go to:** <https://traccar.gtfs.zone>

Sign in with the internal account — `admin@gtfs.zone` and the password in
`gtfs-app-secrets` under `TRACCAR_ADMIN_PASSWORD`:

```bash
kubectl get secret gtfs-app-secrets -n gtfs \
  -o jsonpath='{.data.TRACCAR_ADMIN_PASSWORD}' | base64 -d; echo
```

**Verify:** the console loads and the Devices list appears (empty is fine).

> If you instead log in via Dex, you get a *manager* account, not an admin, and
> it will see **no devices** — Traccar scopes device visibility per user and
> cafe-car creates fleet devices as the admin. That is a known gap, not a bug.
> Share devices with `POST /api/permissions` if you need a manager to see them.

---

## 3. Create the three feeds

**Go to:** <https://manage.rt.gtfs.zone>

Create feeds for **amtrak**, **columbia-county**, and **west**.

**Verify:**
```bash
kubectl exec -n gtfs postgres-1 -c postgres -- \
  psql -U postgres -d rt_api -tAc "select id, name from feeds order by id"
```

---

## 4. Create trackers — the id must match the poller exactly

This is the step with the silent failure. Each poller is hardcoded to a tracker
id, and a mismatch produces **no positions and no error anywhere**.

| Poller Deployment | `INGEST_VEHICLE_ID` | Tracker id you must create |
|---|---|---|
| `hell-gate-bridge-amtrak` | `amtrak-live` | **`amtrak-live`** |
| `hell-gate-bridge-buswhere` | `columbia-county` | **`columbia-county`** |

Confirm what the pods are actually set to rather than trusting this table:
```bash
kubectl get deploy -n gtfs -l app.kubernetes.io/name=hell-gate-bridge \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].env[?(@.name=="INGEST_VEHICLE_ID")].value}{"\n"}{end}'
```

Create a third tracker for the **west** feed — that is the one the driver phone
will use. Any id; you are about to scan its QR.

**Verify:**
```bash
kubectl exec -n gtfs postgres-1 -c postgres -- \
  psql -U postgres -d rt_api -tAc "select id, feed_id from trackers order by id"
```

---

## 5. Confirm the pollers are landing data

The Amtrak poller was already confirmed posting `200 OK`. Once tracker
`amtrak-live` exists, its data should start appearing in the feed rather than
being accepted and dropped.

```bash
kubectl logs -n gtfs -l app=hell-gate-bridge-amtrak --tail=5
```
Expect `POST http://gtfs-api:8000/ingest/position "HTTP/1.1 200 OK"` and a line
like `amtrak: 135 vehicles → 135 positions, 135 trip-updates published`.

**A `401` here means `INGEST_API_TOKEN` is wrong** — note that an *unset* token
sends the literal string `Bearer None` rather than erroring, so 401 is the
symptom to watch for.

> ⚠️ **`hell-gate-bridge-buswhere` will keep failing** with
> `ValueError: could not convert string to float: 'departed'`. That is a known
> app bug, written up in the `hell-gate-bridge` repo as
> `BUSWHERE_DEPARTED_BUG.md`. Columbia County will not report until it is fixed.
> Amtrak is unaffected.

---

## 6. Driver QR path — the phone test

1. In the manage app, generate the **QR code** for the `west` tracker.
2. Install **Traccar Client** on the phone (Play Store / App Store).
3. Scan the QR. It encodes the full URL
   `https://traccar.gtfs.zone/osmand` plus the device's `uniqueId`.
4. Start tracking in the app and let it report at least once.

**Verify — device registered:**
```bash
kubectl exec -n gtfs postgres-1 -c postgres -- \
  psql -U postgres -d traccar -tAc "select id, uniqueid, name from tc_devices"
```

**Verify — position stored by Traccar:**
```bash
kubectl exec -n gtfs postgres-1 -c postgres -- \
  psql -U postgres -d traccar -tAc \
  "select deviceid, latitude, longitude, devicetime from tc_positions order by id desc limit 3"
```

**Verify — it reached Redis via vehicle-poser** (this is the seam cafe-car reads;
keys carry a 60s TTL so check promptly after a report):
```bash
kubectl exec -n gtfs deploy/redis -- redis-cli -n 1 --scan --pattern 'vehicle:*'
```

**Verify — it reached the feed:**
```bash
curl -sS https://rt.gtfs.zone/rt/vehicle-positions.pb | wc -c
```
A non-trivial byte count means vehicles are being published.

If Traccar has the position but Redis does not, look at vehicle-poser:
```bash
kubectl logs -n gtfs -l app=vehicle-poser --tail=30
```

---

## 7. Celery — static GTFS loading

```bash
kubectl logs -n gtfs -l app=celery-beat --tail=20
kubectl logs -n gtfs -l app=celery-worker --tail=30
```

Expect beat to enqueue scheduled tasks and the worker to pick them up. Then
confirm schedule data actually landed:

```bash
kubectl exec -n gtfs postgres-1 -c postgres -- \
  psql -U postgres -d rt_api -tAc "select count(*) from trips"
```

---

## 8. Uptime Kuma status page

`https://status.gtfs.zone/` currently redirects to the private `/dashboard`,
because no public status page exists yet. This matches the old stack's behaviour
— the `tf-monitors/` root that used to configure monitors via API was deleted in
the migration and has no replacement.

Go to <https://uptime.gtfs.zone> (auth-gated), add monitors, then create a
**status page** and publish it. It will be served at
`https://status.gtfs.zone/status/<slug>`.

---

## Quick full-stack smoke test

```bash
for u in https://rt.gtfs.zone/health \
         https://traccar.gtfs.zone/ \
         https://argocd.gtfs.zone/ \
         https://dex.gtfs.zone/.well-known/openid-configuration; do
  printf '%-60s %s\\n' "$u" "$(curl -sS -o /dev/null -w '%{http_code}' "$u")"
done
kubectl get app -n argocd
kubectl get pods -n gtfs
```

All four URLs should return **200**, every Application should be **Healthy**, and
every pod **Running**.

`infra-longhorn` showing *OutOfSync but Healthy* is expected and permanent — the
Longhorn operator mutates its own CRDs — and `root` inherits that status from it.
`gtfs` may flicker to OutOfSync on `Cluster/postgres` just after CNPG touches the
resource, but settles back to Synced on its own; only investigate if it stays
that way.
