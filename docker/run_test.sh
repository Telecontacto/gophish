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
EOF
chmod +x "$test_dir/gophish"

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
echo 'PASS: SQLite default, MySQL configuration, no SQLite writes in MySQL mode, no DSN logging and validation guards'
