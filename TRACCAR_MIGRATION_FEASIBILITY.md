# Feasibility Study: Migrating from OwnTracks to Traccar

> ⚠️ **SUPERSEDED — kept for historical context only.**
>
> The migration this study evaluates has **shipped**. Traccar is deployed and
> running in the k3s cluster; OwnTracks, NanoMQ and `trip-updogger` are retired.
> Nothing here should be treated as a description of the current system, and its
> open questions have all been answered in practice.
>
> For how the stack actually works now, read **`CLAUDE.md`**. For the shipped
> design and the decisions behind it, read **`CURRENT_PLAN.md`** (Phases 5a/6a
> for the ingest layer, Phase 8 for what went wrong in reality) and
> `music-student`'s `docs/traccar.md`.

**Status:** Research / feasibility only — nothing here is built or committed to.
**Date:** 2026-07
**Author:** drafted with Claude Code from web research + current-stack knowledge

---

## 0. TL;DR / Executive Summary

Moving the vehicle-location ingestion layer from **OwnTracks** to **Traccar** is
**feasible and, on balance, an upgrade** for our use case (small bus companies,
low-tech drivers, need for reliable identity, public locations OK). The pieces
we care about all exist:

- **Native Android + iOS client apps** with battery/background handling, plus
  **200+ hardware protocols** for physical trackers — so "phone or dedicated
  device" is a config choice, not a rewrite.
- **QR-code provisioning** (shipped in Traccar 6.8) that encodes the **full**
  device config **including the device identifier** — this is the single most
  important feature for our non-technical drivers and directly enables the
  "hand the driver a sheet of QR codes, one per route" workflow.
- **First-class outbound forwarding** with a built-in **`forward.type=redis`**
  (and `mqtt`, `kafka`, `amqp`, `json` HTTP) — so we can bridge Traccar →
  Redis and keep **everything downstream of Redis identical** to today.
- **Apache 2.0 license** on the server and web — permissive, commercial use and
  paid tiers are fine, no copyleft obligation to publish our modifications.
- **Built-in user/manager/role model + OIDC SSO** — we can wire it to Dex, or
  use Traccar's own manager accounts for bus-company managers.

**The main risks/uncertainties** are: (1) the driver route-switching UX (QR works
today but requires re-scanning; a true `traccar://` deeplink is only "on the
roadmap"); (2) Traccar is a **large opinionated Java monolith with its own SQL
database**, so it's a much heavier component than the thin OwnTracks→Redis bridge
we run now; (3) **identity assurance** is "good enough for public data" but not
cryptographically strong — a device ID in a QR code is a bearer secret; and
(4) operational surface area (another DB, another web UI, another auth surface).

Recommended shape: **run the full Traccar stack, forward positions to Redis via
the native Redis forwarder, and treat everything from Redis onward as unchanged.**
Use QR provisioning now, plan for deeplinks later, and decide deliberately whether
bus-company managers live in Traccar or in our existing Dex/oauth2 world.

---

## 1. Why we're considering this

### 1.1 What OwnTracks gives us today (and its limits)
Today `vehicle-poser` bridges OwnTracks MQTT messages into Redis, and everything
else (cafe-car GTFS-RT API, trip-updogger, schedule-foamer) consumes from there.
OwnTracks is a thin, MQTT-first location publisher. Known pain points that
motivate this study (as framed by the request):

- **Limited provisioning UX** — configuring OwnTracks on a driver's phone is
  fiddly; there's no clean "pick your route" affordance.
- **No device/fleet management layer** — OwnTracks is a publisher, not a
  fleet platform. There's no built-in notion of managers, device inventories,
  per-device limits, groups, geofences, or a management console.
- **Hardware trackers are a separate problem** — OwnTracks is phone-centric;
  supporting dedicated GPS pucks means bolting on something else.
- **Identity is loose** — we rely on MQTT auth (which we recently hardened) but
  there's no fleet-level concept of "this device belongs to this operator."

### 1.2 What we want
- Phones **and** physical devices, on **both** Android and iPhone.
- **Dead-simple driver workflow** — ideally scan/tap once, and to change routes
  select from a short list, with no free-text typing.
- **Reliable identity** — we don't need privacy (locations can be public) but we
  **must** be able to trust that a given feed is who it claims to be.
- **Manager layer** for small bus companies, where a manager can be a Traccar
  manager or a user, and drivers are low-privilege.
- Keep the **downstream architecture stable** — Redis remains the seam.
- **License compatible** with eventually charging above a user threshold.

---

## 2. What Traccar actually is (architecture)

Traccar is an open-source GPS tracking **platform**, not just a publisher. Key
architectural facts relevant to us:

- **Back end:** a single Java service built on **Netty** (async, event-driven).
  It terminates device connections (TCP/UDP), decodes **200+ protocols / 2000+
  device models**, computes events (geofence, overspeed, harsh driving, etc.),
  persists to SQL, and serves a **REST API + WebSocket** stream.
- **Database:** any major SQL DB (MySQL/MariaDB/Postgres; **TimescaleDB**
  supported as of 6.8 for scale). Traccar **owns and manages this schema** via
  its own migrations. The `positions` table holds the raw fixes; `devices` holds
  inventory. Reading the DB directly is possible but **discouraged** (cache
  coherency) — the REST API / forwarding is the supported integration path.
- **Web front end:** `traccar-web` (React), the admin/management console.
- **Mobile:**
  - **Traccar Client** (Android/iOS) — turns a phone into a tracker; talks a
    simple HTTP protocol (default port **5055**).
  - **Traccar Manager** (Android/iOS) — a management/monitoring front end.
  - **Traccar Client SDK** — lets us embed the client behavior into our **own**
    branded app if we ever want to.
- **Deployment:** official Docker images (optimized, with health-check endpoints
  as of 6.8). Fits our Docker-provider Terraform model.

**Mental model vs. today:** OwnTracks is "an MQTT topic with an app." Traccar is
"a whole tracking backend with its own DB, web UI, auth, and device protocol
zoo." That's more power **and** more weight.

---

## 3. The proposed target architecture

```
                    ┌─────────────────────────────────────────────┐
                    │                  Traccar                     │
  Driver phones ───▶│  Netty ingest (HTTP 5055 / hardware ports)   │
  Hardware pucks ──▶│      ↓ decode + enrich + event calc          │
                    │  Traccar SQL DB (own schema, migrations)     │
                    │      ↓                                        │
                    │  forward.type = redis  ───────────────┐      │
                    │  REST API + WebSocket + Web UI         │      │
                    └────────────────────────────────────────┼─────┘
                                                             │
                                                             ▼
                                                    ┌────────────────┐
   (unchanged from here down) ─────────────────────│     Redis      │
                                                    └────────────────┘
                                                             │
                        ┌──────────────┬───────────────┬─────┴────────┐
                        ▼              ▼               ▼              ▼
                    cafe-car     trip-updogger   schedule-foamer   (etc.)
                   (GTFS-RT)      (delays)         (Celery)
```

**Core idea:** Traccar replaces `vehicle-poser` + OwnTracks + NanoMQ *for
location ingestion*, and Traccar's **native Redis forwarder** writes into the
same Redis that everything already reads. The seam moves from "OwnTracks MQTT →
vehicle-poser → Redis" to "Traccar → Redis." **Nothing downstream of Redis needs
to change** if we match the Redis key/value shape.

### 3.1 Two integration variants (pick one)

| Variant | How Traccar reaches Redis | Pros | Cons |
|---|---|---|---|
| **A. Native Redis forward** (`forward.type=redis`) | Traccar writes positions straight to Redis | No custom code; fewest moving parts | We're bound to Traccar's Redis payload shape; a small shim may still be needed to match our exact keys |
| **B. Small bridge service** (Traccar → our code → Redis) | Traccar forwards `json`/`mqtt`/HTTP to a tiny new `traccar-poser`, which writes our exact Redis schema | Full control of Redis schema; can enrich/validate; can keep our current Redis contract byte-for-byte | One more service to run (but it replaces `vehicle-poser`, so net-neutral) |

**Recommendation:** start with **B** (a thin replacement for `vehicle-poser`)
because it lets us keep the **existing Redis contract exactly**, which is what
keeps cafe-car/trip-updogger/schedule-foamer untouched. Revisit **A** later if we
decide to adopt Traccar's payload shape natively. The important point: either way
Redis stays the stable seam.

---

## 4. Feature-by-feature feasibility vs. our requirements

### 4.1 Phones: Android **and** iPhone — ✅ Supported
- Native **Traccar Client** for both platforms, purpose-built to run in the
  background and stream fixes.
- Battery realities are handled but must be configured: Android needs
  **unrestricted background usage** + optional **wake lock**; iOS requires
  **"Always" location** permission and **background execution**, and note the
  **iOS gotcha**: if the user swipes the app away, iOS **kills the process** and
  reporting stops. This is a training/onboarding item, not a blocker.
- **New in 6.8:** server can send **push commands** to the client — request a
  one-off location or enable continuous tracking **even if the app is offline/
  disabled**. Useful for "wake up the driver's phone at shift start."

### 4.2 Physical GPS devices — ✅ Strong
- 200+ protocols / 2000+ models. Hardware pucks connect straight to Traccar on
  their protocol port; no phone involved. This is a **major upgrade** over
  OwnTracks and future-proofs us for operators who want ruggedized trackers or
  hardwired vehicle units.

### 4.3 Driver provisioning via QR — ✅ Works today (this is the big win)
- Traccar 6.8 ships **QR-code configuration** in both the web app and the new
  client. Critically, the QR encodes the **full config, including the device
  identifier** — not just the server URL. Confirmed encodable parameters:
  `id`, `accuracy`, `distance`, `interval`, `angle`, `heartbeat`,
  `fastest_interval`, `buffer`, `wakelock`, `stop_detection`, concatenated with
  `&` (e.g. `accuracy=highest&distance=1&interval=30&heartbeat=3000&wakelock=true&stop_detection=true`).
- **Implication for us:** we can pre-generate **one QR per route/vehicle** with
  the right `id` and tracking profile baked in. The driver's entire job becomes:
  *open app → scan the QR for today's route*. No typing, no server URL, no
  settings. This maps almost perfectly onto the "list of configurations, driver
  selects the right one" idea from the request.

### 4.4 Route switching / the `traccar://` deeplink dream — ⚠️ Partial
- The requested **`traccar://[config]` URL handler / deeplink** does **not yet
  exist** as a shipped feature. It's a long-standing, repeatedly-requested item
  (GitHub issues #355, #471, #39, plus forum threads) and is described as **"on
  the roadmap,"** but as of now the supported mechanism is **QR**, not tap-a-link.
- **What this means practically:**
  - **Today:** route switching = **re-scan a different QR**. That's still very
    low-friction (scan a code on a laminated sheet / dispatcher screen), and it's
    dramatically better than OwnTracks manual config.
  - **A single client instance = a single active config.** Switching routes
    means overwriting the current device `id`. There's an open request (#388) for
    **multiple stored profiles / URLs** in the client — also not shipped.
- **Mitigations / options** (see §7 for the deeper menu):
  1. Ship a **sheet/screen of QR codes** (one per route); driver re-scans to
     switch. Zero dev work.
  2. **Contribute the deeplink feature upstream** (Apache 2.0, so we can) — a
     `traccar://` or `https://configs.<domain>?...` handler; this is the exact
     thing multiple users have asked for and would be broadly welcomed.
  3. Build our **own thin app on the Traccar Client SDK** with a **route picker**
     (a dropdown of pre-defined configs) that internally sets the Traccar device
     id/config. Highest effort, best UX, fully branded.

### 4.5 User / manager / role model — ✅ Good fit
Traccar's built-in RBAC maps cleanly onto "small bus companies with managers and
low-tech drivers":

- **Admin** — us (full server control).
- **Manager** — a bus-company manager: can **register and manage a subset of
  users**, has a configurable **user limit** and device limits, can set
  expiration/disabled on subordinates.
- **User** — could be a driver or a per-vehicle account; can manage their own
  assets.
- **Readonly / device-readonly** — great for public dashboards or drivers who
  shouldn't change anything.
- **Groups** — devices can be grouped (and nested); permissions link users↔devices
  (and geofences, notifications).

**Design question for us (decide deliberately):** do drivers even *need* Traccar
user accounts? For pure ingestion, a **device** (with a `uniqueId`) is enough —
the phone/puck reports against a device id and never logs in. Accounts matter for
**people who log into the web/manager UI**. So a likely model is:

- **Managers = Traccar Manager accounts** (or federated via OIDC/Dex).
- **Drivers = devices, not accounts** (they just scan a QR; no login).
- **Us = Admin.**

This keeps the driver experience login-free while giving managers a real console.

### 4.6 Authentication / SSO integration — ✅ Available
- Traccar supports **OpenID Connect SSO** (`openid.clientId`,
  `openid.clientSecret`, `openid.issuerUrl`, `openid.authUrl`, `openid.tokenUrl`,
  and `openid.force` to **disable internal login** and allow only OIDC). Admin
  rights can be auto-granted via `adminGroup`.
- Also supports **LDAP** (as a user backend).
- **No native SAML** found — OIDC/LDAP only. Fine for us; we already run **Dex**
  as an OIDC provider, so **Traccar → Dex** is a natural wiring if we want unified
  auth. Alternatively, keep Traccar's internal user store for managers and don't
  federate — simpler, fewer moving parts, at the cost of a second identity island.

### 4.7 Public locations — ✅ Fine
We explicitly don't need privacy. Traccar can expose positions publicly via our
own API layer (as today, cafe-car serves the public GTFS-RT feed). Traccar also
has readonly users and shareable views, but our public surface stays **cafe-car**,
fed from Redis, unchanged.

### 4.8 Reliable identity — ⚠️ "Good enough," with caveats
This is the subtle one. Our requirement is *"rely on that they are who they have
been set up as."* Traccar identifies a device by its **`uniqueId`** — a string.
Whatever reports that id, from anywhere, **is** that device to Traccar. So:

- The QR code / device id is effectively a **bearer credential**. Anyone who
  photographs the QR or learns the id can impersonate that vehicle.
- For **public transit data where spoofing is low-value**, this is usually
  acceptable — the same class of trust OwnTracks gave us.
- If we need **stronger** assurance, options include: per-device secrets/tokens
  in the reporting URL, TLS client certs for hardware, rotating ids, or
  server-side sanity checks (geofence/plausibility, speed jumps, teleport
  detection). See §6.4.

---

## 5. Licensing & commercial model — ✅ Clear to proceed

- **Traccar server** and **`traccar-web`** are **Apache License 2.0**.
  (Note: an earlier assumption of AGPL is **incorrect** — the current license is
  Apache 2.0.)
- **Apache 2.0 implications for us:**
  - **Commercial use, modification, and distribution are all permitted**, no
    royalties.
  - **No copyleft** — unlike (A)GPL, we are **not obligated to publish our
    modifications** or our surrounding stack. We can build proprietary features
    (e.g., a route-picker app, billing tiers) on top and keep them closed.
  - We must preserve the license/notice files and attribution.
- **Charging above a user threshold is fine** — nothing in Apache 2.0 restricts
  monetization; the "user limit" mechanics we'd build are our own business logic,
  not a license concern. (Traccar's own **manager `userLimit`** field is even a
  convenient primitive for enforcing per-tenant seat caps.)
- **Verify before shipping:** confirm the license on the **mobile client repos**
  specifically (`traccar-client-android`, `traccar-client`/iOS, and the
  **Client SDK**) — historically Apache 2.0, but if we **fork/rebrand** an app or
  ship via the app stores under our name, re-check each repo's `LICENSE` and any
  trademark/branding constraints on the "Traccar" name and logo. Trademark ≠
  copyright license.

**Action item:** do a quick license audit of every repo we'd actually ship or
modify (server, web, android client, ios client, sdk) and note trademark rules.

---

## 6. Problems, risks, and open questions

### 6.1 Operational weight (biggest architectural change)
- Traccar brings **its own SQL database** and schema/migrations. We already run
  Postgres (multi-tenant) — we'd either add a Traccar database/user there or run
  a separate DB. Either way it's **another stateful component** with backups,
  `prevent_destroy` volumes, and migration lifecycle to own.
- Traccar is a **big Java monolith** vs. our current small bridge. More memory,
  more surface area, more to reason about during incidents.
- We're replacing a component we fully understand (`vehicle-poser`, our code)
  with a large third-party app we don't. That's a **maintainability trade**:
  more features, less control.

### 6.2 The route-switching UX gap
- No shipped deeplink; QR re-scan is the current answer. Acceptable, but it's the
  weakest part of the "driver does almost nothing" goal. Requires a decision on
  the §7 options and possibly upstream/app work.
- **One config per client instance** — if a driver alternates routes mid-day,
  they re-scan each time. If two vehicles share a phone, that's error-prone.

### 6.3 Redis payload matching
- Traccar's native Redis/JSON payload is **its** shape (position id, `deviceId`,
  `uniqueId`, `attributes.*`, `fixTime`, lat/lon/speed/course, etc.), not ours.
  To keep downstream untouched we must **map Traccar's fields → our existing Redis
  keys** (Variant B's shim). Low risk, but it's real integration work and needs
  a careful field-by-field mapping (especially the vehicle→trip/route association
  that OwnTracks encoded implicitly).

### 6.4 Identity assurance (spoofing)
- Device id as bearer secret (see §4.8). For paid/critical operators we may want:
  - **Per-device auth tokens** appended to the report URL (still a bearer secret,
    but rotatable and revocable).
  - **TLS client certificates** for hardware trackers.
  - **Plausibility filtering** server-side: reject impossible jumps, off-route
    teleports, duplicate ids reporting from two places at once (which itself is a
    great **"someone cloned this QR"** signal).
- Decide the **assurance tier per customer** — free/public can be loose; paid can
  be tighter.

### 6.5 iOS reliability
- iOS process-kill-on-swipe and background-permission fragility are inherent to
  the platform, not Traccar's fault, but they **will** generate "my bus
  disappeared" support tickets. Needs an onboarding checklist and maybe in-app
  nagging (a case for the SDK-based custom app).

### 6.6 Mapping "route" to Traccar's data model
- Traccar thinks in **devices, groups, geofences** — it has **no native concept
  of a GTFS route/trip**. The association "this device is currently running route
  X trip Y" lives **in our world**, encoded via the device id / config the driver
  selects, and resolved downstream. We must design that mapping explicitly:
  - Option: **device id encodes the route** (e.g., one device per route, driver
    scans the route's QR) — simplest, but conflates vehicle identity with route.
  - Option: **device = vehicle**, and route is a **Traccar attribute / group**
    the driver's selection sets — cleaner separation, more moving parts.
  - This is arguably the **most important modeling decision** and is discussed in
    §7.
- We must not build our own **route auto-detection** (the request explicitly
  wants to avoid that for reliability) — so the route **must** come from an
  explicit driver action (which QR/config they pick).

### 6.7 Data volume & retention
- Traccar stores **every fix** in SQL. A fleet reporting every few seconds
  generates a lot of rows. TimescaleDB support (6.8) helps, but we need a
  **retention/cleanup policy** and to size storage. Our current OwnTracks→Redis
  path doesn't durably store history the same way, so this is **new data
  lifecycle** to own.

### 6.8 Migration & dual-run
- Cutover from OwnTracks to Traccar shouldn't be a big bang. We'll want a period
  where **both** feed Redis (or a shadow Redis) so we can compare. That means
  temporarily running OwnTracks/NanoMQ **and** Traccar — extra complexity during
  transition.

### 6.9 What we'd retire / keep
- **Likely retire for location ingest:** OwnTracks, and possibly **NanoMQ** *if*
  its only job was OwnTracks MQTT. But NanoMQ may serve other purposes — confirm
  before removing. `vehicle-poser` gets **replaced** by a Traccar→Redis shim.
- **Keep:** Redis, cafe-car, trip-updogger, schedule-foamer, Traefik, Dex,
  oauth2-proxy, Postgres, monitoring — all downstream of the seam.
- **Note:** if NanoMQ stays for other reasons, we could even have Traccar forward
  via **`forward.type=mqtt`** into NanoMQ and keep `vehicle-poser` almost as-is —
  a lower-churn migration path worth considering (Variant C).

---

## 7. Design options for the driver route-selection UX (deep dive)

This is the crux of the whole project, so here's the full menu, worst-to-best
effort:

### Option 1 — QR sheet, one code per route (zero dev)
- Pre-generate a QR per route/vehicle with device `id` + tracking profile baked
  in. Print a laminated sheet or show on a dispatcher screen.
- Driver: open app → scan the route's QR. To switch routes, scan a different one.
- **Pros:** works **today**, no code, dead simple to explain.
- **Cons:** re-scan to switch; QR is a bearer secret; physical sheet management.

### Option 2 — Dispatcher-driven push (low dev)
- Use 6.8 **push commands** to remotely start/stop tracking. Combine with Option
  1 so the office can "activate" a driver at shift start.
- **Pros:** less driver action; central control.
- **Cons:** still one config per phone; doesn't solve mid-day route switching by
  itself.

### Option 3 — Contribute the `traccar://` deeplink upstream (medium dev, high leverage)
- Implement the widely-requested deeplink/URL handler in the open-source client
  (Apache 2.0 lets us, and upstream wants it). Then a driver taps a link from a
  list ("Route 5 AM", "Route 12 PM") and the app configures itself.
- **Pros:** best-in-class UX with **stock apps**; benefits the community; we don't
  maintain a fork if it's merged.
- **Cons:** upstream review timeline outside our control; until merged we carry a
  patch or fork.

### Option 4 — Custom branded app on the Client SDK (highest dev, best UX)
- Build "OurBus Driver" on the **Traccar Client SDK** with a **route picker**
  (a dropdown of pre-defined, server-provided configs), our branding, and
  guardrails for the iOS background gotchas.
- **Pros:** ideal low-tech UX (pick from a list, no scanning), full control,
  can enforce identity (per-device tokens), can nag about iOS permissions,
  supports **multiple stored profiles** natively.
- **Cons:** most work; app-store maintenance on two platforms; we own the app
  lifecycle. Re-verify SDK license + Traccar trademark for store listing.

**Recommendation:** **Start with Option 1 (+2)** to ship fast and validate the
whole Traccar→Redis pipeline with real drivers. In parallel, **pursue Option 3**
(deeplink) as the medium-term UX, and hold **Option 4** as the endgame if/when we
monetize and want a branded, identity-hardened experience.

---

## 8. Data model: mapping our world onto Traccar

Recommended starting model (revisit after a pilot):

- **Device = physical reporter** (a specific phone or puck), with a stable
  `uniqueId`. This is the durable identity.
- **Route/assignment = selected config**, expressed as either:
  - the **QR/config the driver scans** (fastest to ship), or
  - a **Traccar attribute/group** set at assignment time (cleaner long-term).
- **Manager = bus company** (Traccar Manager account, optionally via Dex OIDC),
  with `userLimit`/device limits enforcing per-tenant seat caps that also feed
  our future **billing threshold**.
- **The route↔device association is resolved in our shim/downstream**, never by
  auto-detection. The driver's explicit selection is the source of truth.

Open modeling questions to settle in the pilot:
1. One device **per vehicle** or **per route**? (Prefer per-vehicle; carry route
   as an attribute — but per-route QR is the quickest MVP.)
2. Where does the **GTFS trip/route id** get attached — in Traccar attributes, or
   purely in our Redis shim keyed by device id?
3. How do we **revoke** a compromised/cloned device id cleanly?

---

## 9. Proposed phased plan (no build yet — just the shape)

1. **Spike / lab (1 stack):** Stand up Traccar + a scratch DB in Docker locally.
   Register a test device, run Traccar Client on a real phone, confirm fixes
   land. **Turn on `forward.type=redis`** (or a tiny shim) and watch data hit a
   scratch Redis. *Goal: prove the seam.*
2. **Redis contract mapping:** Define the exact field mapping Traccar → our
   existing Redis schema (Variant B shim, replacing `vehicle-poser`). Prove
   cafe-car serves a valid GTFS-RT feed from Traccar-sourced data **unchanged**.
3. **Provisioning UX pilot:** Generate per-route QR codes; run a **real driver
   trial** with one small operator. Measure: setup time, error rate, iOS
   reliability, route-switch friction.
4. **Identity & retention hardening:** decide assurance tier (tokens? plausibility
   filtering?), set DB retention/cleanup, size storage.
5. **Manager/auth decision:** Traccar-native manager accounts vs. Dex OIDC
   federation. Wire whichever we pick.
6. **Terraform-ify:** add Traccar (+DB, volumes with `prevent_destroy`, DNS,
   Traefik routes, forwarding config, secrets) following the repo's existing
   file-organization conventions. Add all new variables to
   `secrets.auto.tfvars.example` per CLAUDE.md.
7. **Dual-run & cutover:** run OwnTracks and Traccar in parallel feeding
   (shadow) Redis; compare; then flip. Decommission OwnTracks (and NanoMQ **iff**
   unused elsewhere).
8. **Later / optional:** deeplink upstream contribution (Option 3) and/or branded
   SDK app (Option 4); billing threshold enforcement via manager `userLimit`.

---

## 10. Decision checklist (things to explicitly choose)

- [ ] **Integration variant:** A (native Redis), B (our shim — *recommended*), or
      C (forward via MQTT into existing NanoMQ/`vehicle-poser`).
- [ ] **Driver UX path:** QR sheet now; deeplink and/or SDK app later — how far do
      we commit?
- [ ] **Do drivers get accounts?** (Recommended: **no** — drivers are devices;
      only managers/us log in.)
- [ ] **Auth:** federate Traccar to **Dex (OIDC)** or use Traccar-native users?
- [ ] **Data model:** device-per-vehicle vs device-per-route; where the GTFS
      route id lives.
- [ ] **Identity tier(s):** loose (public/free) vs token/cert-hardened (paid).
- [ ] **Database:** reuse existing Postgres (new DB/user) vs dedicated Traccar DB;
      retention policy; TimescaleDB or not.
- [ ] **NanoMQ fate:** retire or keep (does anything else use it?).
- [ ] **License audit** done on every repo we ship/modify (+ trademark check).

---

## 11. Bottom line

Traccar can do **everything OwnTracks does for us and materially more**: native
dual-platform apps, hardware protocol support, a real management/RBAC layer, OIDC
SSO, and — crucially — **QR provisioning that bakes in the device identity and
full config**, which is close to the low-tech-driver experience we want. The
**Apache 2.0 license fully supports commercial use and paid tiers with no
copyleft burden.** The **Redis seam lets the entire downstream stack stay put.**

The real work and risk are **not** "can Traccar do it" (it can) but:
1. **the route-switching UX** (QR today, deeplink/app later),
2. **owning a heavier component** (Java monolith + its own SQL DB), and
3. **identity assurance & data lifecycle** decisions.

None of these are blockers. Recommend proceeding to a **lab spike (§9.1–9.3)** to
prove the Traccar→Redis seam and pilot QR provisioning with one operator before
committing to a full Terraform integration.

---

## Appendix A — Sources

- Traccar home / features — https://www.traccar.org/
- GitHub: traccar/traccar — https://github.com/traccar/traccar
- Architecture — https://www.traccar.org/architecture/
- Pricing — https://www.traccar.org/pricing/
- License (Apache 2.0) — https://github.com/traccar/traccar/blob/master/LICENSE.txt
- Commercial use forum — https://www.traccar.org/forums/topic/traccar-for-commercial-purposes/
- User Management — https://www.traccar.org/user-management/
- Permissions and Groups — https://www.traccar.org/permissions-groups/
- Forwarding (position/event, incl. `redis`) — https://www.traccar.org/forward/
- OpenID Connect SSO — https://www.traccar.org/openid-sso/
- LDAP — https://www.traccar.org/ldap/
- Client (Android/iOS) — https://www.traccar.org/client/
- Client Configuration — https://www.traccar.org/client-configuration/
- Client Troubleshooting — https://www.traccar.org/client-troubleshooting/
- Client SDK — https://www.traccar.org/blog/traccar-client-sdk
- Traccar 6.8 release (QR config, push commands, TimescaleDB) — https://www.traccar.org/blog/traccar-6-8/
- QR config guide / parameters — https://www.traccar.org/forums/topic/qr-code-configuration-guide-how-to-add-mode-option-to-qr/
- Deeplink feature request (client) — https://github.com/traccar/traccar-client-android/issues/471
- Custom URL / QR pre-config request — https://github.com/traccar/traccar-client-android/issues/355
- Multiple URL/profile support request — https://github.com/traccar/traccar-client-android/issues/388
