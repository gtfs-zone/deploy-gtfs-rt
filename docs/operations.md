# Operations

## Cluster access

**Run kubectl on the node over SSH.** The `KUBECONFIG` export is required: the
remote user's `~/.kube/config` is an empty stub. `/etc/rancher/k3s/k3s.yaml` is
mode 644, so no sudo.

```bash
ssh kcfam 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n argocd get pods'
```

An SSH tunnel also works, but it has proven flaky under load (it died mid-run
during a helm upgrade and hung the openapi fetch):

```bash
ssh -N -L 6443:127.0.0.1:6443 kcfam
```

`helm` is not in the node's default PATH; there is a copy at `~/bin/helm` on
`kcfam`, put there because running helm on the node beats running it through the
tunnel.

ArgoCD UI: `https://argocd.gtfs.zone`, via **Log in via Keycloak** (the `argocd`
client in the `gtfs` realm). Access requires membership in the `argocd-admins`
Keycloak group; `policy.default` is empty, so a realm account without it can
sign in and see nothing. CLI: `argocd login argocd.gtfs.zone --sso`.

Keycloak admin console: `https://id.gtfs.zone/admin/gtfs/console`, with a normal
realm account (GitHub/Google/GitLab brokered) that is in the `keycloak-admins`
group; that group carries the `realm-management` `realm-admin` client role and
scopes to the `gtfs` realm only. The master-realm `admin`
(`KEYCLOAK_ADMIN_PASSWORD` in `gtfs-app-secrets`) stays break-glass.

The local `admin` account is kept enabled as **break-glass**, because Keycloak
runs in the `gtfs` namespace against the CNPG cluster ArgoCD itself deploys:
if the `gtfs` app is broken, SSO is down too.

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

**ArgoCD is not self-managed.** `infra/argocd/values.yaml` (SSO, RBAC, the KSOPS
sidecar) is applied by hand, and always with a pinned chart version so the
change does not also bump ArgoCD:

```bash
helm upgrade argocd argo/argo-cd -n argocd --version 10.1.4 -f infra/argocd/values.yaml
```

## Working on this repo

**Cross-repo work is allowed.** The sibling `gtfs.zone` repos (see *Related
repositories* below) live under the same parent directory; read and edit them
directly when a change spans repos. There is no "this repo only" restriction.

**There are no `apply` commands.** Commit and push to the branch ArgoCD tracks
(`apps/root.yaml` -> `targetRevision`); ArgoCD syncs automatically. To force a
re-read: `kubectl annotate app <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite`.

**Before every commit, render the tree the way ArgoCD's KSOPS CMP does:**

```bash
PATH="$HOME/.local/bin:$PATH" SOPS_AGE_KEY_FILE=$PWD/age.key \
  kustomize build --enable-alpha-plugins --enable-exec gtfs
```

Standalone `kustomize` is not installed on the dev machine; install it for the
above. `kubectl kustomize --enable-alpha-plugins gtfs` renders everything else
but silently skips the KSOPS generator, so it does not check secrets.

**Validate Helm value changes by rendering the real chart** rather than reasoning
about defaults; several chart-default bugs in this stack were only visible in
the rendered output:

```bash
helm template <release> <repo>/<chart> --version <v> -n <ns> -f infra/<comp>/values.yaml
```

**Editing a secret:** use `sops set` (it does not print plaintext). You rarely
need to decrypt: SOPS leaves key names readable.

**Images:** CI publishes `:vX.Y.Z` + `:latest` on `v*` tags only. Bumping an image is a manifest edit plus a commit. The `ghcr.io/gtfs-zone`
packages are public (anonymously pullable), so no `imagePullSecrets` are used.

## Patterns worth knowing

**Monitoring is declarative.** Uptime Kuma was replaced by Gatus because Kuma
keeps monitors, notifications and status pages only in a SQLite file, with no
config file and no supported API; it ran for weeks with zero monitors and no
status page and nothing surfaced it. Adding a check is an edit to
`gtfs/gatus/config.yaml`, which is hash-suffixed into a ConfigMap so the edit
rolls the Deployment. Gatus stores history in memory only: no PVC, no database,
history resets on restart.

Alerts go to Telegram, to the same `@kcfam_bot` and chat that home-docker's
Uptime Kuma uses, so gtfs.zone and kcfam.us page the same place. The token and
chat id live in `gtfs-app-secrets` (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`)
and reach the config as `${VAR}`, so they never enter the ConfigMap. Note that
`default-alert` under the provider is a **template, not an opt-out**: an endpoint
sends nothing unless it also carries its own `alerts: - type: telegram`.
Verified against v5.36.0. Validate a config change by running the image against
the file before pushing:

```bash
docker run --rm -e TELEGRAM_BOT_TOKEN=1:x -e TELEGRAM_CHAT_ID=1 \
  -v $PWD/gtfs/gatus/config.yaml:/config/config.yaml:ro \
  twinproduction/gatus:v5.36.0
```

The in-cluster checks (Postgres, Redis, rt-traccar-receiver, the osmand port) fail
under that local run, by design; the public ones are real. Public hostnames are
checked by their real URL, not Service DNS, so a check exercises DNS, the edge
passthrough and the cert; hairpin NAT back to `73.4.232.254` works from inside
the cluster.

**Database migrations** run as an ArgoCD **PreSync hook Job**
(`gtfs/rt-api-migrate.yaml`) using the `gtfs-zone-db-models` migrations, so Alembic
completes before any rollout. If a hook Job wedges, ArgoCD's `hook-finalizer`
deadlocks against its own stuck operation; clear the operation
(`kubectl patch app <n> -n argocd --type merge -p '{"operation":null}'`)
*before* removing the finalizer.

**Adding auth to a service:** attach both Middlewares to its IngressRoute route,
in this order:

```yaml
middlewares:
  - name: oauth2-errors
  - name: oauth2-proxy
```

Note Traefik's `errors` middleware serves the sign-in page **while preserving the
original 401 status code**: a 401 whose body is oauth2-proxy's Sign In page is
correct behaviour, not a failure.

**Adding a hostname:** add an `IngressRoute` with the
`external-dns.alpha.kubernetes.io/target: "73.4.232.254"` annotation; external-dns
creates the Porkbun record from it. Remember a DNS wildcard matches exactly **one**
label: `*.gtfs.zone` does not cover `anything.rt.gtfs.zone`, which is why
`gtfs-zone-tls` also carries `*.rt.gtfs.zone`.

**Traccar config:** `CONFIG_USE_ENVIRONMENT_VARIABLES=true` makes env override
`traccar.xml`. The env name is **not** simply the key uppercased: Traccar inserts
an underscore before each capital first, so `openid.clientSecret` is
`OPENID_CLIENT_SECRET`. Getting this wrong is silent: the pod stays healthy and
only `/api/server` breaks.
