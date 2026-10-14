# Railway deployment analysis

## Administrative HTTPS proxy follow-up

This section supersedes earlier statements below that no admin HTTP domain or
supervisor is implemented. The default remains loopback admin TLS; opt-in proxy
mode adds Railway HTTPS → Nginx HTTP :3334 → GoPhish HTTP 127.0.0.1:3333. Campaign
HTTP on :8080 and its `/health` route are unchanged. This is one GoPhish process,
not a service split. No schema, database configuration or migration was changed.

### Configuration and security

```text
ADMIN_PROXY_ENABLED=true
ADMIN_LISTEN_URL=127.0.0.1:3333
ADMIN_USE_TLS=false
ALLOW_PUBLIC_ADMIN=false
ADMIN_TRUSTED_ORIGINS=gophish-production-7157.up.railway.app
PORT=8080
PHISH_LISTEN_URL=0.0.0.0:8080
```

Preserve **all existing** DB_NAME/DB_PATH/DB_DSN, optional MySQL CA configuration,
certificate files and /data volume. Route the administrative domain to 3334, not
3333; leave campaign domain and healthcheck routed to 8080. The additional
`ADMIN_PROXY_ENABLED` opt-in is required; merely disabling TLS does not start Nginx.

Inspected the locked Gorilla CSRF v1.6.2 implementation: unsafe HTTPS requests
check Referer; trusted values are compared to `referer.Host`, not a full origin
URL. Correct format is comma-separated **host[:port], no scheme/path/wildcard**.
Gorilla handlers v1.4.2 `ProxyHeaders` sets request URL scheme from
X-Forwarded-Proto before CSRF executes. Nginx preserves Host, sets forwarded Host,
forces HTTPS and overwrites Forwarded/client IP headers. It reports the immediate
peer's IP rather than trusting a client-supplied IP chain. Do not expose port 3334
via raw TCP or untrusted HTTP routing; it is exclusively for the Railway HTTPS edge.

New admin JSON fields `secure_cookies` and `disable_access_log` default false for
native/backward compatibility. Proxy mode forces both true. Session and CSRF
cookies use `use_tls || secure_cookies`: internal HTTP therefore does not weaken
cookie transport security. CSRF/authentication/API-key checks are unchanged. The
API keeps its existing CSRF exemption. No client TLS validation is disabled.
HTTP admin outside localhost remains prohibited; proxy mode specifically requires
127.0.0.1:3333 and ALLOW_PUBLIC_ADMIN=false. Config override flags are rejected in
proxy mode so callers cannot bypass these constraints.

The panel/API become **publicly reachable** with authentication, not IP-restricted.
Any IP allowlist/VPN/edge restriction must be configured explicitly by the operator.
Nginx access/error request logs and GoPhish admin combined access logs are disabled
in proxy mode: Nginx errors and combined logs can contain query-string API keys.
No proxy logs capture Authorization, cookies or bodies. Existing operational and
campaign logs remain; the upstream bootstrap password logging remains a sensitive
existing limitation. Clients should prefer Bearer API authentication.

### Runtime and compatibility

Runtime adds Debian nginx/python3 and `docker/supervise.py`. Root bootstrap and
selective volume ownership remain; GoPhish, supervisor and Nginx execute as UID/GID
10001. Nginx PID/body/proxy/other temporary directories live under a private /tmp
prefix, not /var/run, /var/log or /data. Configuration remains private with umask
077, never printed; supervisor deletes its generated JSON on shutdown.

The supervisor validates Nginx before starting GoPhish, launches separate process
groups, detects even unexpected clean exits, stops the sibling and exits nonzero.
TERM/INT gracefully QUIT Nginx and TERM GoPhish; after 25 seconds remaining process
groups receive KILL and direct children are reaped. Use a platform stop allowance
of at least 30 seconds. Existing GoPhish mail/IMAP drain limitations remain.

Arguments are passed as an argv list, not shell text. `--mode admin` and
`--disable-mailer` remain supported. Campaign-only mode (`--mode phish` or
`--mode=phish`) and help/version execute GoPhish directly without Nginx. Non-proxy
startup is unchanged; proxy mode rejects `--config`/`--config=...` overrides.

### Verification results and remaining integration checklist

Executed locally on Windows with Git Bash/jq and a stub executable:
`bash docker/run_test.sh` passed for SQLite/MySQL, private config generation,
no DSN output, proxy cookie/origin settings, argument handoff, config override
rejection and retained non-loopback HTTP security guards.

`python3 -B docker/supervise_test.py` passed all six mocked unit tests: graceful
signals, unexpected application exit, Nginx exit, forced shutdown timeout,
configuration failure and partial startup failure. This does not test real Unix
signals/process groups on Windows. Shell syntax and `git diff --check` passed.

Go handler regression tests passed with Go 1.26.8, CGO/Zig and locked dependencies:
`TestAdminProxySecurity`, `TestPublicHealth`, `TestPublicDoesNotExposeAdmin`.
The proxy test uses a synthetic in-memory SQLite database, no network listeners,
SMTP/IMAP or campaign workers. It verifies login and settings, Secure/HttpOnly
CSRF/session cookies, invalid/missing Referer and CSRF rejection, authenticated
read-only API and 401 without a key. Forwarded headers emulate the Nginx contract;
this is **not** an end-to-end Nginx test.

The complete `go test -mod=readonly ./...` was attempted: controllers,
controllers/api and webhook tests abort because Windows forbids their loopback
socket listeners. Other tested packages passed. The full suite is **not passing**
in this environment; rerun it on a Linux runner with networking.

The optimized Linux/amd64 Go binary build passed with CGO/Zig against glibc using
`-mod=readonly -trimpath -ldflags="-s -w"`. This is a cross-compilation check,
not a Docker image build or Linux runtime test.

Docker build was attempted but Docker is not installed. Before production, run
on a Linux Docker host with **only isolated test data and volumes**:

1. Build `docker build -t gophish-railway-proxy-test .`; run the configuration and
   Python supervisor tests. Validate `nginx -t` with the private prefix.
2. Start with the variables above and a new test /data volume (never production
   DB_DSN), publish campaign 8080 and proxy 3334 on **host loopback only**. Use a
   local HTTPS reverse proxy with a trusted development certificate for 3334,
   or an isolated Railway staging service with HTTPS. Do not use insecure TLS
   client options; Secure cookies intentionally will not work over plain HTTP.
3. Inspect `/proc/1/status` and Nginx/GoPhish processes: UID/GID must be 10001.
   Confirm listeners :3334, 127.0.0.1:3333 and :8080; admin 3333 must not bind publicly.
4. Verify real HTTPS login/settings, cookies, CSRF failures, API without key 401
   and read-only API with a synthetic test key. Inspect logs using only synthetic
   sensitive markers to prove headers, URI keys and bodies are not recorded.
5. Check public `/health`; verify a harmless test landing page without sending
   emails/launching campaigns. Stop/restart and replace the container with the
   same test volume to check data persistence.
6. Send TERM/INT to PID 1; check both processes drain/exit. Kill either child in a
   test container and verify the sibling stops and the container fails for restart.
   Test forced timeout and startup failure. Also test a pre-owned volume with
   `--user 10001:10001` to verify no-root startup.

Live Nginx/container startup, listeners, HTTPS-edge TLS, process failure/signals,
non-root filesystem ownership and persisted data across replacement remain
unverified here. No production service was contacted, deployed or modified.

### Deployment/rollback and PHP

Follow the [README deployment/rollback procedure](../README.md#administrative-https-domain-through-railway-opt-in):
consistent backup, one replica, preserve DB variables and volumes, validate staging,
then authorized deployment and admin domain switch to 3334. Keep the current TCP
Proxy definition until verification, but it stops working during the switch:
there is no simultaneous public TLS listener once 3333 becomes loopback HTTP.
For rollback restore previous release/admin TLS variables and TCP Proxy routing
on the **same storage**; do not delete/import/recreate the database or certificates.

PHP: `GOPHISH_API_URL=https://gophish-production-7157.up.railway.app`; keep the API
key and standard certificate/hostname checks, remove only the previous self-signed
GOPHISH_CA_FILE override and restart Apache. Nothing is pushed/published/deployed
by this implementation.

## Original architecture and structure

- `gophish.go`: main entrypoint; reads `./VERSION` before parsing Kingpin CLI
  flags. `--config` defaults to `./config.json`; modes are `all`, `admin`, `phish`.
- `config/`: JSON loading and configuration types, no native environment overrides.
  `LoadConfig` appends `db_name` to `migrations_prefix` and forces `test_flag=false`.
- `controllers/route.go`: admin HTTP server, templates and authenticated API.
  `controllers/phish.go`: public campaign tracking, reporting, landing pages.
  Both use Gorilla mux, gzip, forwarded proxy headers and combined access logs.
- `auth/`, `middleware/`, `context/`: password hashing, sessions, CSRF, permissions,
  rate limiting and request context. Not redesigned for this deployment.
- `models/`: GORM v1 persistence and domain models. `Setup` opens the configured
  database, limits connections to one, applies Goose SQL migrations and seeds the
  initial admin. SQLite currently defaults to `gophish.db` in the working directory.
  Goose uses `db/db_sqlite3` (discovers its `migrations/` directory); MySQL has a
  separate migration tree. Both are now included in the runtime image.
- `worker/`, `mailer/`, `imap/`: background sending and mailbox reporting, started
  with admin mode. Mail locks are unlocked at process startup. The mail worker has
  no shutdown/drain method; IMAP cancellation does not wait for network work.
- `dialer/`, `webhook/`: restricted outbound clients; internal host restrictions
  remain unchanged. `logger/`: Logrus writes stderr, optionally also a local file.
- `util/`: includes generation of self-signed certificates when TLS is enabled.
  Original admin config uses HTTPS on `127.0.0.1:3333`; public config uses HTTP
  on `0.0.0.0:80`. Certificates are generated only when both paths are absent.
- `static/`, `templates/`, `db/`: external runtime data, not embedded in the binary.
- `gulpfile.js`, `webpack.config.js`, `package.json`, `yarn.lock`: frontend tooling;
  already committed `dist` bundles are used unchanged in this phase. CKEditor
  loads from `static/js/src/vendor/ckeditor`, so excluding all `src` would break UI.
- `.github/workflows/`: CI declares Go 1.21/1.22/1.23; release workflow uses 1.22
  and packages frontend bundles, CKEditor, templates, migrations and GeoIP data.
- `ansible-playbook/`: existing systemd/nginx deployment, not needed in Docker.
  `doc/`, contribution/security/license documents: project documentation.
- Original `Dockerfile`: Node `latest` frontend build, Go 1.15.2, Debian slim,
  copies the entire source tree, capabilities for privileged ports and rewrites
  admin to `0.0.0.0`. `docker/run.sh` rewrites JSON repeatedly, prints it, has no
  `PORT` support and does not `exec` the binary.

`go.mod` declares **Go 1.13**, a minimum language version, not a requirement to
use an obsolete compiler. The new builder uses maintained Go **1.26.8**, without
changing module versions or the language directive. `mattn/go-sqlite3` needs CGO,
so the builder installs a C toolchain. An initial cross-build against musl failed
because this SQLite version references `pread64`, `pwrite64` and `off64_t`. Rather
than patching SQLite or changing its compile-time semantics, builder and runtime
use Debian Bookworm/glibc (slim runtime). Old Goose, GORM, SQLite and x/crypto
warrant future maintenance; compatibility must be verified, not inferred from age.

## Exact runtime inventory

Under the fixed working directory `/opt/gophish`:

| Path | Why needed |
| --- | --- |
| `gophish` | Linux executable, compiled with CGO enabled. |
| `VERSION` | Mandatory read before CLI/configuration startup. |
| `config.json` | Base settings for the entrypoint; original file unchanged. |
| `db/db_sqlite3/migrations/*.sql` | All existing SQL migrations, automatically applied at startup. |
| `db/db_sqlite3/dbconf.yml` | Included with the existing migration tree for compatibility; runtime uses the Go-built DB configuration. |
| `db/db_mysql/**` | Existing MySQL SQL migrations and configuration, used only when `DB_NAME=mysql`. |
| `templates/*.html` | All admin views, shared base/navigation/flashes and login/reset views. |
| `static/js/dist/**` | Existing application and vendor bundles. |
| `static/js/src/vendor/ckeditor/**` | Editor code, adapters, plugins, styles, skins, language and image assets loaded dynamically. |
| `static/css/dist/**` | Existing bundled stylesheet. |
| `static/images/**`, `static/font/**` | UI assets, fonts and email tracking pixel. |
| `static/db/geolite2-city.mmdb` | Campaign GeoIP enrichment, opened by `models/result.go`. |
| `static/endpoint/` | Public static-file root (currently empty except `.gitignore`); persist custom content separately if used. |
| `LICENSE` | Included license notices. |

Outside the working directory: `/usr/local/bin/gophish-entrypoint`, `/bin/sh`,
`jq`, `gosu`, CA trust (SMTP/HTTPS outbound), timezone data, glibc runtime and
app UID/GID entries. No Go, GCC, Node, npm, frontend build tools, test fixtures,
Git metadata or application source in the final image. SQLite files and admin
certificates live in `/data`; private generated JSON lives in `/tmp`.

The other source/vendor JS and unbundled CSS are not needed by the templates.
User-provided public endpoint files are preserved if present in the build context;
files written at runtime outside a volume will not survive replacement.

## Railway risks and chosen minimal changes

- **Proxy:** public GoPhish already supports HTTP behind a reverse proxy without
  core changes. Railway terminates HTTPS; public certificates are never generated.
  Forwarded client IP headers are trusted upstream, so do not expose the internal
  public port through an additional untrusted raw TCP route.
- **Ports/bind:** original port 80 requires root/capabilities. Entrypoint selects
  `0.0.0.0:$PORT` (8080 fallback), with explicit public-bind override. Admin stays
  loopback/TLS unless an operator explicitly opts into exposure.
- **Admin:** no new routing/proxy layer, authentication changes or public admin
  HTTP domain. Private tunneling is preferred; optional TCP Proxy with internal
  TLS provides access in one deployment but deliberately increases attack surface.
  Two-service split is documented, not implemented; SQLite volume sharing would
  not make that architecture safe or supported on Railway.
- **Filesystem:** fixed WORKDIR preserves all original relative asset paths.
  `/data` is prepared after the volume mounts; a root-only bootstrap changes
  ownership of configured directories and known DB/certificate files, then drops
  to UID 10001. No recursive chown, schema change or database conversion.
- **Signals:** `exec` makes GoPhish PID 1; SIGTERM joins SIGINT handling. Normal
  `http.ErrServerClosed` no longer aborts shutdown via `log.Fatal`. IMAP monitor
  initialization is synchronous (it immediately launches its goroutine), avoiding
  an uninitialized cancel function during shutdown. HTTP shutdown is bounded;
  full mail/IMAP draining remains an upstream limitation.
- **Logs:** stderr already works. Docker selects no local log file and does not
  print generated configuration. Original temporary password logging is retained,
  so restrict access to Railway logs.
- **Health:** minimal public GET `/health` before the campaign catch-all returns
  JSON with no database writes, campaign events, secrets or admin information.
  This reserves that exact route and is liveness only; startup has already run DB
  setup before listeners start. Railway's health check is not ongoing monitoring.
- **Contact:** main now passes the existing `WithContactAddress` option so the
  configured contact actually reaches the existing transparency response.
- **TLS:** self-signed admin certificate behavior retained and files persisted.
  It has no SAN; production access needs operator-provisioned certificates or a
  fingerprint-verified endpoint exception. Cookies/CSRF remain Secure with TLS.
- **Operations:** one replica, no sleeping, consistent backups before upgrades,
  no overlapping SQLite writers during deployments. Existing session keys are
  ephemeral; upgrades may log users out. No dependency security audit performed.

## Verification

### MySQL follow-up (fresh installation)

At the operator's request, Docker now accepts `DB_NAME=mysql` plus a secret
`DB_DSN` in the existing Go driver's format. SQLite remains the default. Both
migration trees are copied into the image; MySQL mode skips SQLite directory/file
initialization entirely. Optional `DB_SSL_CA_PATH` maps to the existing config
field (custom CA requires `tls=ssl_ca` in the DSN). Initial backend enablement
changed no database driver, SQL migration, model, auth or dependency. No remote service was created,
no SQLite data was removed/imported and no credentials were added to Git.

Follow-up checks: `bash docker/run_test.sh` passed with real jq and an executable
stub: SQLite default, MySQL JSON, ignored SQLite path, custom CA mapping, no DSN
logging, missing DSN/URL/unsupported-backend rejection and admin security guards.
`TestLoadMySQLConfig` also passed: the documented DSN parses using the existing
MySQL driver with datetime/UTC options, and `LoadConfig` discovers the MySQL
migration tree without opening a connection. SQLite config and public health/
admin-isolation regression tests passed separately. The optimized Linux/amd64
CGO build passed again. The full Go suite was rerun;
the same three network-dependent packages failed on Windows socket permissions.
Docker build was attempted again but Docker is still unavailable. **Live MySQL
connectivity, MySQL SQL migrations and authentication/version compatibility are
not verified in this environment.** Follow the fresh-install staging checks in
the README before production; retain the app's volume for admin certificates.

### MySQL strict-mode startup correction

A live deployment reported Error 1292 while creating the bootstrap admin:
the legacy driver's zero `time.Time` was serialized as a MySQL zero date for
`users.last_login`. The existing column is nullable, but GORM explicitly included
the zero value in both the initial INSERT and the password's subsequent UPDATE.

`User.BeforeSave` now omits `last_login` only for MySQL when it is unset. New
users receive the column's existing SQL NULL default, and pre-login password/
account updates leave that NULL untouched. Real login timestamps still save
normally. SQLite behavior and the original JSON zero-time representation remain
unchanged. There is no schema migration, database reset, fake login timestamp,
SQL mode override or authentication change. An existing partially initialized
database can retry normal startup after deployment; it need not be deleted.

`TestMySQLUserUnsetLastLogin` exercises real GORM MySQL INSERT/UPDATE generation
over a local SQLite connection with a CHECK rejecting invalid dates. It verifies
SQL NULL on creation and password update, NULL reload, preservation of other
fields/omissions, real login timestamp persistence and unchanged SQLite scope
behavior. This is a regression test of SQL generation, not a live MySQL server
test; deployment against strict-mode MySQL remains the final integration check.
The regression test and full `models`/`config` tests passed, as did the optimized
Linux/amd64 CGO build. The full Go suite was rerun with the same Windows socket
permission failures in controllers, API and webhook; other packages passed.

### Initial SQLite deployment verification

Environment: Windows, no installed Docker or WSL Linux distribution. Go 1.26.8
and Zig 0.13.0 were downloaded into the approved temporary directory (archives
checksum-verified); no global tools or system configuration were modified.
Direct module downloads from the Go executable were denied by the environment,
so an external temporary file-based module proxy was populated via PowerShell.
Go still verified module contents against the unchanged `go.sum`. The local
verification used `GOSUMDB=off` with that locked mirror only; the Dockerfile uses
normal Go checksum verification and does not disable it.

| Check | Result |
| --- | --- |
| `go test ./...` | Initial attempt blocked by outbound socket permissions during dependency download. |
| `CGO_ENABLED=1 go test -mod=readonly ./...` | Compiled all packages. Auth, config, dialer, logger, mailer, middleware, rate limiter, models, util and worker passed. Controllers, API and webhook aborted because `httptest` could not bind IPv6 loopback (`socket access forbidden`). Suite is **not fully passing** here. |
| New public health/admin-isolation tests | Passed separately with CGO; use `httptest.NewRecorder`, without network listeners. |
| Linux/amd64 optimized build with CGO | Passed using Zig C cross-compilation against glibc, Go 1.26.8, `-mod=readonly -trimpath -ldflags="-s -w"`. Not an actual Docker/GCC build. |
| Windows optimized build with CGO | Passed, enabling a native startup check. |
| Native startup (`--mode admin`, then `--mode phish`) | Created a real 122880-byte SQLite DB, applied migrations, generated admin certificate/key and logged startup URLs to stderr. Both exited with socket-permission errors when binding IPv4 loopback; listener connectivity could not be checked. |
| SQLite persistence | Passed: a temporary standalone harness called the existing models against a real SQLite file, saved a harmless group, then verified it from a second process. Second startup had no migrations left to run. Not a Railway Volume test. |
| Entrypoint configuration | Passed in Git Bash with real jq and a stub executable: JSON generation, `PORT`, explicit public override, contact, stderr logging selection, admin opt-in and TLS guards. Root bootstrap/Unix file ownership not tested by this harness. |
| Shell syntax, Go formatting, diff whitespace | Passed. |
| `docker build -t gophish-railway .` | Attempted; Docker command is not installed. |

**Still unverified:** actual Docker image build/size/dynamic-library resolution,
Linux container startup and UID/volume ownership, live public/admin listeners,
real HTTP health requests, SIGTERM draining, persistence across container
replacement and actual Railway routing/Volume/TCP Proxy behavior. The README
contains the Linux-container smoke test to run before production deployment.
No generated databases, passwords, certificates, binaries or tool caches were
added to the repository. `go.mod`, `go.sum` and the original `config.json` remain
unchanged.

## Next steps (not implemented)

1. Run the Docker smoke test and full Go suite on a Linux runner with networking;
   validate Railway staging with a Volume before an authorized production run.
2. Choose restricted administrative connectivity or explicitly approve TCP Proxy
   exposure; provision a hostname-valid certificate and test login/CSRF/reset.
3. Establish protected, consistent SQLite backups and restoration tests; add
   ongoing external monitoring beyond deployment-time liveness.
4. Later, audit and modernize dependencies (including SQLite), then consider mail
   worker draining, proxy trust boundaries, durable auth keys and any future DB/UI
   work separately. None of those migrations is part of this change.

References: [Railway public networking](https://docs.railway.com/guides/public-networking),
[TCP Proxy and HTTP in one service](https://docs.railway.com/networking/tcp-proxy).
