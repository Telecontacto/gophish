![gophish logo](https://raw.github.com/gophish/gophish/master/static/images/gophish_purple.png)

Gophish
=======

![Build Status](https://github.com/gophish/gophish/workflows/CI/badge.svg) [![GoDoc](https://godoc.org/github.com/gophish/gophish?status.svg)](https://godoc.org/github.com/gophish/gophish)

Gophish: Open-Source Phishing Toolkit

[Gophish](https://getgophish.com) is an open-source phishing toolkit designed for businesses and penetration testers. It provides the ability to quickly and easily setup and execute phishing engagements and security awareness training.

### Install

Installation of Gophish is dead-simple - just download and extract the zip containing the [release for your system](https://github.com/gophish/gophish/releases/), and run the binary. Gophish has binary releases for Windows, Mac, and Linux platforms.

### Building From Source
**If you are building from source, please note that Gophish requires Go v1.10 or above!**

To build Gophish from source, simply run ```git clone https://github.com/gophish/gophish.git``` and ```cd``` into the project source directory. Then, run ```go build```. After this, you should have a binary called ```gophish``` in the current directory.

### Docker
You can also use Gophish via the official Docker container [here](https://hub.docker.com/r/gophish/gophish/).

### Deploying on Railway

This fork's Dockerfile runs a **single instance** with two separate listeners:
public HTTP behind Railway HTTPS, and an HTTPS admin listener on loopback by
default. It uses the committed frontend bundles, without rebuilding or changing
the UI. See [the deployment analysis](doc/railway.md) for runtime requirements,
security tradeoffs and verification results. Use only for authorized engagements.

#### Service and persistent storage (SQLite default)

1. Create a Railway project/service from your fork's GitHub repository. Set its
   root directory to the directory containing `go.mod`, `Dockerfile` and
   `railway.toml` (`gophish` if the outer directory is committed).
2. Attach a **Railway Volume** to this service with mount path **`/data`**, before
   the first deployment. Set `DB_PATH=/data/gophish.db`. Do not mount over
   `/opt/gophish`, which contains the application assets.
3. Set `CONTACT_ADDRESS` to your team's contact email. Leave the start command
   unset: the Docker entrypoint handles configuration and privilege dropping.
4. Deploy. `railway.toml` selects Docker, checks `GET /health`, and restarts failed
   processes. GoPhish applies the existing SQLite migrations automatically.
5. In Settings -> Networking, generate an HTTPS domain targeting the public
   listener's `PORT`, **never 3333**. Railway normally supplies `PORT`; the local
   fallback is 8080. If you set `PHISH_LISTEN_URL`, explicitly align its port,
   `PORT` and the domain target port. Use the HTTPS domain as the campaign URL.
6. Review deployment logs in Railway or with `railway logs`. Initialization and
   HTTP access logs go to stderr. The original application logs the temporary
   admin password: restrict log access and change that password immediately.

The entrypoint starts briefly as root to prepare mounted-directory ownership,
then runs GoPhish as UID/GID **10001**. SQLite, its journal files and admin
certificates remain on the volume. If running the image with `--user 10001:10001`,
pre-create writable data/certificate directories with that ownership yourself.
In SQLite mode, `DB_PATH` must be an absolute filename, not `:memory:` or a
SQLite URI. A path outside the mounted volume is **not persistent**.

#### Environment variables (Docker entrypoint)

| Variable | Default / purpose |
| --- | --- |
| `PORT` | Railway supplied; 8080 locally. Public bind is `0.0.0.0:$PORT`. |
| `PHISH_LISTEN_URL` | Optional explicit `host:port`; takes precedence over `PORT`. |
| `ADMIN_LISTEN_URL` | `127.0.0.1:3333`; separate administrative listener. |
| `ADMIN_USE_TLS` | `true`; `false` allowed only on loopback. |
| `ADMIN_CERT_PATH` | `/data/gophish_admin.crt`. |
| `ADMIN_KEY_PATH` | `/data/gophish_admin.key`. |
| `ALLOW_PUBLIC_ADMIN` | `false`; explicit opt-in required for any non-loopback admin bind, including private networking. TLS remains required. |
| `ADMIN_TRUSTED_ORIGINS` | Optional comma-separated admin origins in the existing GoPhish format (`host[:port]`, without scheme). No wildcard. |
| `DB_NAME` | `sqlite3`; also accepts `mysql`. Selects the existing migration tree. |
| `DB_PATH` | SQLite only: `/data/gophish.db`; legacy `DB_FILE_PATH` is accepted as a fallback. Ignored in MySQL mode. |
| `DB_DSN` | Required for MySQL: Go driver DSN, not a `mysql://` URL. Store as a secret. |
| `DB_SSL_CA_PATH` | Optional MySQL CA certificate path; use `tls=ssl_ca` in the DSN to enable existing custom-CA support. |
| `CONTACT_ADDRESS` | Empty; set to your team's contact email. |
| `LOG_LEVEL` | `info`; existing Logrus levels. |
| `GOPHISH_INITIAL_ADMIN_PASSWORD` | Existing optional bootstrap secret, only while password change is required. Set through Railway secrets, never Git. |
| `GOPHISH_INITIAL_ADMIN_API_TOKEN` | Existing optional initial-user API token secret. |

This image supports SQLite or MySQL, with public HTTP only (`PHISH_USE_TLS`, if
set, must be `false`). Native binary
configuration via `--config` is unchanged. Generated configuration is private,
ephemeral and never printed; it does not need to live on the volume.

#### MySQL on Railway (fresh database, no data import)

1. Add a MySQL service in the **same Railway project/environment** as GoPhish.
   Use a dedicated empty database. Keep MySQL's persistent volume attached to the
   database service and use its **private** hostname/port, not a public TCP proxy.
2. On the GoPhish service, set `DB_NAME=mysql` and create a secret `DB_DSN` in
   **Go MySQL driver format**. For a database service named `MySQL`, Railway
   variable references can be composed as follows (adjust the service name):

   ```text
   ${{MySQL.MYSQLUSER}}:${{MySQL.MYSQLPASSWORD}}@tcp(${{MySQL.MYSQLHOST}}:${{MySQL.MYSQLPORT}})/${{MySQL.MYSQLDATABASE}}?charset=utf8mb4&parseTime=true&loc=UTC
   ```

   Confirm `MYSQLHOST` resolves to the private service address and `MYSQLPORT`
   is the internal MySQL port. Do **not** paste `MYSQL_URL` directly: its
   `mysql://...` URL format is not the DSN expected by this Go driver. The database
   must already exist; GoPhish creates tables/migrations, not the database itself.
   `parseTime=true` is needed for MySQL datetime fields; use UTC consistently.
3. Remove/unset obsolete database connection overrides if desired; `DB_PATH` and
   `DB_FILE_PATH` are ignored in MySQL mode. **Do not delete the existing GoPhish
   `/data` volume:** it still persists the admin certificate/key. SQLite files
   are left untouched and are neither imported into MySQL nor deleted.
4. Deploy GoPhish. The existing `db/db_mysql` migrations initialize the empty
   database and create a **new** admin user with a new temporary password in logs.
   Log in, change the password, and verify a harmless group persists on redeploy.
   Public/admin routing and TLS remain exactly as before.

Use a dedicated database user scoped to the GoPhish database rather than a
shared/root account for production. It needs runtime read/write privileges and
DDL privileges to apply the existing migrations (`CREATE`, `ALTER`, `DROP`,
`INDEX`); do not grant global administrative privileges. Keep credentials only
in Railway secrets/reference variables, never Git or screenshots.

Private networking is not the same as database TLS authentication. If the MySQL
server provides TLS, use `tls=true` with a publicly trusted CA, or `tls=ssl_ca`
with `DB_SSL_CA_PATH` pointing to a securely provisioned CA file. The private
connection example above does not enable database TLS. Do not use
`tls=skip-verify`, disable server validation, or weaken MySQL authentication to
work around connection errors. The legacy driver/migrations still require a live
compatibility test against your chosen MySQL version; do not assume every future
MySQL version is compatible.

To verify entrypoint configuration without running a database, install Bash/jq
on a Linux runner and execute `bash docker/run_test.sh`. This test does not verify
live MySQL connectivity or SQL migration compatibility. Once the deployment is
healthy, test admin login, password change, harmless group/template persistence,
and startup on redeploy. `/health` becomes available only after DB setup, but it
is not a continuous database connectivity check.

#### Administrative access: safe default and explicit alternatives

The public domain does **not** serve `/login` or `/api/`. With the default
loopback bind, there is intentionally no remote browser access to the admin.
Railway SSH provides a remote shell, not an automatically configured TCP tunnel;
do not assume `railway connect` forwards this application.

- **Preferred restricted access:** establish an authenticated tunnel into the
  container's loopback listener using your organization's VPN/tunneling solution.
  Alternatively expose admin only to a controlled Railway private network using
  `ADMIN_LISTEN_URL=[::]:3333` and `ALLOW_PUBLIC_ADMIN=true`; provide a VPN gateway
  to that network. The private network is not directly accessible from a laptop.
  This repository does not install or configure a tunnel/VPN.
- **Simplest browser-access option in the same deployment:** deliberately enable
  a Railway **TCP Proxy** targeting port 3333, set
  `ADMIN_LISTEN_URL=0.0.0.0:3333`, `ALLOW_PUBLIC_ADMIN=true`, and retain
  `ADMIN_USE_TLS=true`. Visit `https://<tcp-proxy-host>:<assigned-external-port>`.
  The public campaign domain still targets `PORT`. The TCP proxy passes TLS
  through: **Railway does not supply the admin certificate for this connection**.
  This makes the authenticated admin panel reachable from the Internet, without
  an IP allowlist provided by this implementation. Approve this exposure before
  enabling it; prefer restricted access when possible. Do not put a Railway HTTP
  domain in front of this TLS listener and do not disable its TLS.

GoPhish preserves its original certificate generation for admin only. The
self-signed certificate has no hostname SAN; it cannot pass normal public PKI
validation. For a production TCP proxy, securely provision a certificate/key
valid for the chosen admin hostname using the configurable paths. Otherwise
verify the self-signed certificate's SHA-256 fingerprint through an authenticated
Railway shell (`openssl x509 -in /data/gophish_admin.crt -noout -fingerprint -sha256`,
if OpenSSL is available) before accepting a browser exception for that endpoint.
Do not disable certificate validation globally. Missing *both* certificate files
triggers generation; a partially provisioned pair must be repaired by an operator.
Authentication, password reset, CSRF and secure cookies remain intact.

**Splitting into two application services is not implemented.** The existing
`--mode admin` / `--mode phish` flags could support that architecture, but two
services cannot simply share a
Railway SQLite Volume. It requires a different database/storage architecture and
coordination of migrations and the mail worker; defer this to a later phase.
Using a separate MySQL database service does not split the GoPhish application.

#### Updates, backups and limitations

Push changes to the connected branch or redeploy the service; keep persistent
volumes. For MySQL, configure database backups on its service and test restoration;
keep one GoPhish replica because the original mail worker/startup locks are not
designed for coordinated replicas. Back up SQLite consistently before updates
(SQLite backup API, or stop the process and copy the database), protect the
backups and test restoration.
Never copy only an actively written database while ignoring journals. Use one
replica; do not run two processes against the database during rollout. Expect
brief downtime with volume-backed deployments; disable sleeping/serverless mode
because mail scheduling and IMAP monitoring require a running process.

`/health` returns `200 {"status":"ok"}` after database setup. It is a listener
liveness check, not continuous database/SMTP/IMAP readiness. It reserves the
public `/health` route. SIGTERM/SIGINT drain HTTP requests (up to 10 seconds per
listener); the original mail worker has no drain interface, so SMTP sends in
flight can still be interrupted. Configure a platform stop allowance of at least
30 seconds where available. Session/CSRF keys remain process-local as upstream,
so deployments can require signing in again. Legacy dependencies and GeoIP data
are unchanged; compilation is not a security audit. Confirm Railway's acceptable
use policy and outbound SMTP connectivity before an authorized campaign.

#### Local smoke test (Docker with Linux containers)

Run from the directory containing the Dockerfile:

```sh
docker build -t gophish-railway .
docker volume create gophish-data
docker run -d --name gophish-local -e PORT=8080 -e CONTACT_ADDRESS=security@example.org -e ADMIN_LISTEN_URL=0.0.0.0:3333 -e ALLOW_PUBLIC_ADMIN=true -p 127.0.0.1:8080:8080 -p 127.0.0.1:3333:3333 -v gophish-data:/data gophish-railway
docker logs gophish-local
curl http://127.0.0.1:8080/health
docker exec gophish-local sh -c 'ls -l /data; grep -E "^(Uid|Gid):" /proc/1/status'
docker stop --time 30 gophish-local
docker start gophish-local
curl http://127.0.0.1:8080/health
```

Open `https://localhost:3333`, verify the local certificate, log in, change the
temporary password and create a harmless test group. After the stop/start, check
that it still exists and credentials still work. To verify persistence across
container replacement, remove **only** this stopped test container, then repeat
the `docker run` command using the same named volume. Do not delete the volume.
The explicit admin opt-in above permits container networking, but the host port
is published only on loopback. For Linux source checks (Go and GCC installed):

```sh
CGO_ENABLED=1 go test ./...
CGO_ENABLED=1 go build -mod=readonly -trimpath -ldflags="-s -w" -o gophish .
```

### Setup
After running the Gophish binary, open an Internet browser to https://localhost:3333 and login with the default username and password listed in the log output.
e.g.
```
time="2020-07-29T01:24:08Z" level=info msg="Please login with the username admin and the password 4304d5255378177d"
```

Releases of Gophish prior to v0.10.1 have a default username of `admin` and password of `gophish`.

### Documentation

Documentation can be found on our [site](http://getgophish.com/documentation). Find something missing? Let us know by filing an issue!

### Issues

Find a bug? Want more features? Find something missing in the documentation? Let us know! Please don't hesitate to [file an issue](https://github.com/gophish/gophish/issues/new) and we'll get right on it.

### License
```
Gophish - Open-Source Phishing Framework

The MIT License (MIT)

Copyright (c) 2013 - 2020 Jordan Wright

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software ("Gophish Community Edition") and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
