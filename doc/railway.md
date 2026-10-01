# Railway deployment analysis

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
  separate migration tree, not included in the SQLite runtime image.
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
