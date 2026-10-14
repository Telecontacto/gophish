#!/usr/bin/env bash
# Configuration regression tests without a database, sockets or root privileges.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cp "$repo/config.json" "$test_dir/config.json"
cat > "$test_dir/gophish" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = --config ]
jq -e --arg backend "$DB_NAME" --arg connection "${DB_DSN:-${DB_PATH:-}}" \
    --arg ca "${DB_SSL_CA_PATH:-}" \
    '.db_name == $backend and .db_path == $connection and .db_sslca_path == $ca and
     .migrations_prefix == "/opt/gophish/db/db_" and .logging.filename == "" and
     .phish_server.listen_url == "0.0.0.0:9123" and .phish_server.use_tls == false' "$2" >/dev/null
if [ "${ADMIN_PROXY_ENABLED:-false}" = true ]; then
    jq -e '.admin_server.listen_url == "127.0.0.1:3333" and
           .admin_server.use_tls == false and .admin_server.secure_cookies == true and
           .admin_server.disable_access_log == true and
           .admin_server.trusted_origins == ["gophish-production-7157.up.railway.app"]' "$2" >/dev/null
fi
shift 2
[ "$*" = "${EXPECTED_ARGS:-}" ]
[ "${SUPERVISOR_STUB_CALLED:-false}" = "${EXPECTED_SUPERVISOR:-false}" ]
EOF
chmod +x "$test_dir/gophish"
cat > "$test_dir/python3" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = /opt/gophish/supervise.py ]
[ -f "$GOPHISH_RUNTIME_CONFIG" ]
# The real supervisor is tested separately. Verify exact argv handoff here.
shift
export SUPERVISOR_STUB_CALLED=true
exec "$@"
EOF
chmod +x "$test_dir/python3"
export PATH="$test_dir:$PATH"

run_entrypoint() (
    # Override only working-directory/UID discovery. exec invokes the stub above;
    # the production entrypoint itself is loaded unchanged.
    cd() { builtin cd "$test_dir"; }
    id() { echo 10001; }
    source "$repo/docker/run.sh"
)
expect_failure() {
    if run_entrypoint > "$test_dir/output" 2> "$test_dir/error"; then
        echo 'Expected invalid configuration to fail' >&2
        exit 1
    fi
    grep -q 'Configuration error:' "$test_dir/error"
}

unset DB_NAME DB_DSN DB_FILE_PATH DB_SSL_CA_PATH PHISH_LISTEN_URL PHISH_USE_TLS
unset ADMIN_LISTEN_URL ALLOW_PUBLIC_ADMIN ADMIN_USE_TLS
unset ADMIN_PROXY_ENABLED ADMIN_TRUSTED_ORIGINS EXPECTED_ARGS EXPECTED_SUPERVISOR SUPERVISOR_STUB_CALLED
export DB_PATH="$test_dir/sqlite/gophish.db" PORT=9123
export ADMIN_CERT_PATH="$test_dir/certs/admin.crt" ADMIN_KEY_PATH="$test_dir/certs/admin.key"
run_entrypoint
[ -d "$test_dir/sqlite" ]

export DB_NAME=mysql DB_DSN='smoke:synthetic-password@tcp(mysql.internal:3306)/gophish?parseTime=true&loc=UTC&charset=utf8mb4'
export DB_PATH="$test_dir/ignored-sqlite/gophish.db"
export DB_SSL_CA_PATH="$test_dir/custom-ca.pem"
run_entrypoint > "$test_dir/output" 2> "$test_dir/error"
[ ! -d "$test_dir/ignored-sqlite" ]
! grep -q 'synthetic-password' "$test_dir/output" "$test_dir/error"

unset DB_DSN
expect_failure
export DB_DSN='mysql://smoke:synthetic-password@mysql.internal/gophish'
expect_failure
export DB_NAME=postgres
expect_failure
export DB_NAME=sqlite3 DB_PATH=relative.db
unset DB_DSN
expect_failure
export DB_NAME=mysql DB_DSN='smoke:synthetic-password@tcp(mysql.internal:3306)/gophish?parseTime=true'
export ADMIN_LISTEN_URL=0.0.0.0:3333
expect_failure
export ALLOW_PUBLIC_ADMIN=true ADMIN_USE_TLS=false
expect_failure
export ADMIN_PROXY_ENABLED=true ADMIN_LISTEN_URL=127.0.0.1:3333 ALLOW_PUBLIC_ADMIN=false
export ADMIN_TRUSTED_ORIGINS=gophish-production-7157.up.railway.app
export EXPECTED_SUPERVISOR=true
run_entrypoint
export EXPECTED_ARGS='--mode admin --disable-mailer'
run_entrypoint --mode admin --disable-mailer
unset EXPECTED_ARGS
expect_failure_with_args() {
    if run_entrypoint "$@" > "$test_dir/output" 2> "$test_dir/error"; then
        echo 'Expected argument validation to fail' >&2; exit 1
    fi
    grep -q 'Configuration error:' "$test_dir/error"
}
expect_failure_with_args --config=/test.json
expect_failure_with_args --config /test.json
export EXPECTED_ARGS='--mode phish'
export EXPECTED_SUPERVISOR=false
run_entrypoint --mode phish
export EXPECTED_ARGS=--mode=phish
run_entrypoint --mode=phish
export EXPECTED_ARGS=--version
run_entrypoint --version
export EXPECTED_ARGS=--help
run_entrypoint --help
unset EXPECTED_ARGS
export EXPECTED_SUPERVISOR=true
export DB_NAME=sqlite3 DB_PATH="$test_dir/sqlite/gophish.db"
unset DB_DSN
run_entrypoint
export ADMIN_USE_TLS=true
expect_failure
export ADMIN_USE_TLS=false ADMIN_LISTEN_URL=localhost:3333
expect_failure
export ADMIN_LISTEN_URL=127.0.0.1:3333 ADMIN_TRUSTED_ORIGINS=https://gophish-production-7157.up.railway.app
expect_failure
export ADMIN_TRUSTED_ORIGINS='*.up.railway.app'
expect_failure
unset ADMIN_TRUSTED_ORIGINS
expect_failure
export ADMIN_PROXY_ENABLED=invalid
expect_failure
echo 'PASS: SQLite/MySQL, private config, secret-free output, proxy secure cookies/origins, argv and security guards'
