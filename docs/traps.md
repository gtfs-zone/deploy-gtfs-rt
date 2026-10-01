# Traps and known gaps

## Traps that have already bitten

Each of these cost real debugging time.

- **Template calls inside comments.** Both gomplate (Dex config) and Traefik's
  file provider template the *entire file, comments included*. A template
  expression written in a comment to document syntax gets executed, and the whole
  file is discarded, silently, in Traefik's case.
- **Keycloak's `pkce.code.challenge.method` is a requirement, not an offer.**
  Setting it on a client makes Keycloak demand a `code_challenge` on *every*
  flow of that client. argocd-server's browser login is a confidential-client
  code flow that sends none, so the whole sign-in failed with `invalid_request:
  Missing parameter: code_challenge_method`. The argocd client does not set it.
- **Keycloak realm import is create-only.** `gtfs/keycloak/gtfs-realm.json` is
  applied when the realm does not exist and never again, so editing it changes
  nothing on the running Keycloak. Every group, client scope and client change
  has to be made a second time by hand (admin console, or `kcadm.sh` inside the
  pod) and the file kept in sync for the next fresh realm. Nothing detects the
  drift.
- **Helm `pre-upgrade` hooks under ArgoCD** become PreSync hooks and run before
  the chart's own ServiceAccount exists. Longhorn ships one; it is disabled via
  `preUpgradeChecker.jobEnabled: false`.
- **Helm release names change ServiceAccount names.** The cert-manager Porkbun
  webhook must be told `certManager.serviceAccountName: infra-cert-manager`.
- **DNS-01 apex/wildcard collision.** `gtfs.zone` and `*.gtfs.zone` validate at
  the same TXT name and the Porkbun webhook replaces rather than appends, so
  requesting both on one Certificate deadlocks issuance.
- **Longhorn volumes mount root-owned and contain a `lost+found`,** which makes
  some images skip their own permission fixup. Use `fsGroup`.
- **Chart-default port mismatches.** The external-dns chart hardcodes the webhook
  sidecar's containerPort/probes to 8080 while the Porkbun webhook binary
  defaults to :8888. Always render the chart.
- **Host inotify limits.** k3s + Longhorn + containerd share root's
  `fs.inotify.max_user_instances`; at the default 128 they exhausted it and
  home-docker's Traefik could not start its file provider at all. Raised to 1024
  in `/etc/sysctl.d/99-inotify.conf`.
- **Garage picks the bucket from the Host header.** The `s3_web` endpoint looks a
  Host that does not end in its `root_domain` up as a bucket global alias, which
  is why the public bucket is aliased literally `data.gtfs.zone`. A Traefik
  Host-rewrite middleware in front of it rewrites the bucket name and returns a
  404 that never says why. On the S3 side, `S3_REGION` is part of the SigV4
  signature, so a mismatch with `garage.toml`'s `s3_region` is a 403 rather than a
  redirect, and `PutBucketCors` is refused from a key without `owner` on the
  bucket.
- **`DAGSTER_HOME` must be a directory the image owns.** `/app` is root-owned and
  the image runs as `bridge`, so the default lands somewhere unwritable and fails
  late and confusingly, not at startup: the same trap as static-importer-beat's
  `--schedule`. It is `/app/dagster_home`, and the instance config is mounted into
  it by `subPath` so the directory itself stays writable.
- **Dagster runs live inside the code-server pod.** With `DefaultRunLauncher`, an
  image bump during the ~40 min daily run kills the run process, and nothing can
  see it die (`DefaultRunLauncher` has no worker health check): the run sits in
  STARTED, and with `max_concurrent_runs: 1` it holds the queue. What frees it is
  `max_runtime_seconds` moving it to CANCELING and `cancel_timeout_seconds`
  marking it CANCELED; a UI cancel alone leaves it in CANCELING forever.
- **Two oauth2-proxies must not share anything.** `oauth2-proxy-admin` has its
  own cookie name, its own Redis DB and a cookie domain of exactly
  `dagster.gtfs.zone`; two instances both writing `_oauth2_proxy` on `.gtfs.zone`
  hand each other's sessions back and forth. The protected host also needs an
  unprotected, longer `PathPrefix(`/oauth2/`)` route, or the sign-in page's own
  CSS and the callback re-enter the auth chain and the login never completes.
- **Gatus conditions have no clock.** They cannot express "generated in the last
  day", so freshness is an `external-endpoints` heartbeat the producer pushes, not
  a condition on a polled body.
- **The shared app shell has an import order.** Each app's `src/shell.ts` mounts
  the markup and must stay the first import in `index.ts`, since other modules
  look element ids up at evaluation time. The shell stylesheet's `@import` must
  directly follow `@import 'tailwindcss'`: postcss rejects an `@import` after any
  other statement. A gtfs-zone-web-common tag left unpushed breaks
  `pnpm install` for every app that repins; push it with `--follow-tags`.

## Known gaps

- **Two producers share the `trip_update:*` namespace,** and they divide it by a
  `source` stamp, not by key prefix. `rt-delay-estimator` stamps every record it writes
  `source: rt-delay-estimator` and refuses to touch a key that lacks that stamp, so
  rt-pollers' richer per-stop predictions always win and rt-delay-estimator only
  fills the gaps. rt-api's `/ingest/trip-update` writes **no** `source` field,
  which is what makes this work; if a future producer ever starts writing that
  field, it will silently start losing its records to the sweeper.
- **`compute_delay` has no notion of a trip that hasn't started.** For a trip whose
  first stop is still hours away it projects the parked vehicle onto a later stop
  and reports a large bogus "early" delay (observed: −11700s on an Amtrak trip 3h
  before departure). Only visible on trips rt-pollers did not itself predict,
  since those keys are deferred to. Fix belongs in `rt-delay-estimator`'s `trip_math.py`.
- The `columbia-county` poller crashes every cycle on a `"departed"` string in
  buswhere's `stop_eta` (app bug; written up in `rt-pollers`'
  `BUSWHERE_DEPARTED_BUG.md`). Amtrak is unaffected.
- `infra-longhorn`'s CRDs and `gtfs`'s `Cluster/postgres` no longer show spurious
  OutOfSync, see `ignoreDifferences` in `apps/infra-longhorn.yaml` and
  `apps/gtfs.yaml`. Both the Longhorn CRD conversion webhook (self-injected
  `caBundle`) and CNPG's own mutating admission webhook (defaults ~18 `Cluster`
  spec fields, plus role defaults) write fields at persist time that are never in
  the applied manifest; with SSA, ArgoCD attributes those to its own field
  manager, so only explicit `jsonPointers`/`jqPathExpressions` fix it; this is
  *not* transient and does not resolve itself. If either Application goes
  OutOfSync again on a *new* field after a chart/operator upgrade, diff
  `helm template`/`kubectl get -o yaml` output against the live object to find
  the newly-defaulted path and add it to the same list.
- **Traccar scopes device visibility per user, and being an administrator does
  not change that.** `openid.adminGroup` grants the admin console (Users,
  Settings) but the device list is still driven by the `tc_user_device` join
  table, so a fresh OIDC admin logs in and sees zero devices until each one is
  shared with `POST /api/permissions`. Confirmed the hard way: all 7 devices were
  linked only to `admin@gtfs.zone` (rt-api's service account), and the first
  real OIDC admin login saw none of them. The table is many-to-many, so granting
  a second user does not take access away from the first.

  Mitigated, not closed: every device now belongs to the Traccar group **All
  Vehicles** (`settings.traccar_device_group`, set by rt-api's
  `ensure_device`), so a new admin is one share of that group rather than one
  share per device. That share is still manual, in the UI or
  `POST /api/permissions {"userId": N, "groupId": G}`. A device created outside
  rt-api, by hand in the Traccar UI, gets no group and stays invisible.
- **Logical feed grouping can false-merge,** and there is no override file yet.
  Grouping is by URL and host/path shape only, so unrelated systems that share a
  download URL become one feed (the largest group seen is 9, PTV's nested zips on
  one download). The fix belongs in feed-catalog.
- No backups yet. CNPG scheduled backups + Longhorn snapshots are the obvious
  next step now that Traccar keeps durable position history.
