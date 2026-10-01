#!/bin/sh
set -eu
umask 077
cd /opt/gophish

export DB_PATH="${DB_PATH:-${DB_FILE_PATH:-/data/gophish.db}}"
export ADMIN_LISTEN_URL="${ADMIN_LISTEN_URL:-127.0.0.1:3333}"
export ADMIN_USE_TLS="${ADMIN_USE_TLS:-true}"
export ADMIN_CERT_PATH="${ADMIN_CERT_PATH:-/data/gophish_admin.crt}"
export ADMIN_KEY_PATH="${ADMIN_KEY_PATH:-/data/gophish_admin.key}"
export PHISH_LISTEN_URL="${PHISH_LISTEN_URL:-0.0.0.0:${PORT:-8080}}"

fail() { echo "Configuration error: $*" >&2; exit 1; }

case "$DB_PATH" in
    /*) ;;
    *) fail 'DB_PATH must be an absolute SQLite filename (not a DSN)' ;;
esac
[ "$(dirname "$DB_PATH")" != / ] || fail 'DB_PATH must be inside a data directory'
[ "${DB_NAME:-sqlite3}" = sqlite3 ] || fail 'This image supports SQLite only'
[ "${PHISH_USE_TLS:-false}" = false ] || fail 'Public TLS must terminate at the reverse proxy'
case "$ADMIN_USE_TLS" in true|false) ;; *) fail 'ADMIN_USE_TLS must be true or false' ;; esac

# Refuse accidental exposure, even if the platform selects the wrong target port.
case "$ADMIN_LISTEN_URL" in
    127.0.0.1:*|localhost:*|\[::1\]:*) ;;
    *)
        [ "${ALLOW_PUBLIC_ADMIN:-false}" = true ] || fail 'Non-loopback admin requires ALLOW_PUBLIC_ADMIN=true (also applies to private networking)'
        [ "$ADMIN_USE_TLS" = true ] || fail 'Non-loopback admin requires HTTPS'
        echo 'WARNING: admin is listening beyond loopback; restrict access and do not route the public HTTP domain to it.' >&2
        ;;
esac

if [ "$(id -u)" = 0 ]; then
    # Only touch the configured data directories and known application files;
    # never recursively change ownership of a user's mounted volume.
    mkdir -p "$(dirname "$DB_PATH")"
    chown app:app "$(dirname "$DB_PATH")"
    for file in "$DB_PATH" "$DB_PATH-journal" "$DB_PATH-wal" "$DB_PATH-shm"; do
        if [ -f "$file" ]; then chown app:app "$file"; chmod 600 "$file"; fi
    done
    if [ "$ADMIN_USE_TLS" = true ]; then
        for file in "$ADMIN_CERT_PATH" "$ADMIN_KEY_PATH"; do
            [ "$(dirname "$file")" != / ] || fail 'Admin certificates must be inside a dedicated directory'
            mkdir -p "$(dirname "$file")"
            chown app:app "$(dirname "$file")"
            if [ -f "$file" ]; then chown app:app "$file"; chmod 600 "$file"; fi
        done
    fi
    exec gosu app:app /usr/local/bin/gophish-entrypoint "$@"
fi

mkdir -p "$(dirname "$DB_PATH")"
[ -w "$(dirname "$DB_PATH")" ] || fail 'SQLite directory is not writable by UID 10001'
if [ "$ADMIN_USE_TLS" = true ]; then
    mkdir -p "$(dirname "$ADMIN_CERT_PATH")" "$(dirname "$ADMIN_KEY_PATH")"
fi

# Generate JSON safely, retaining existing security settings from the base config.
# Never print the resulting config (it may contain sensitive overrides).
runtime_config=$(mktemp /tmp/gophish-config.XXXXXX)
jq \
    --arg admin "$ADMIN_LISTEN_URL" \
    --argjson admin_tls "$ADMIN_USE_TLS" \
    --arg cert "$ADMIN_CERT_PATH" --arg key "$ADMIN_KEY_PATH" \
    --arg phish "$PHISH_LISTEN_URL" --arg db "$DB_PATH" \
    --arg contact "${CONTACT_ADDRESS:-}" \
    --arg origins "${ADMIN_TRUSTED_ORIGINS:-}" \
    --arg level "${LOG_LEVEL:-info}" \
    '.admin_server.listen_url = $admin |
     .admin_server.use_tls = $admin_tls |
     .admin_server.cert_path = $cert | .admin_server.key_path = $key |
     (if $origins != "" then .admin_server.trusted_origins = ($origins | split(",")) else . end) |
     .phish_server.listen_url = $phish | .phish_server.use_tls = false |
     .db_name = "sqlite3" | .db_path = $db |
     .migrations_prefix = "/opt/gophish/db/db_" |
     .contact_address = $contact | .logging = {filename: "", level: $level}' \
    config.json > "$runtime_config"

# LoadConfig appends db_name to migrations_prefix.
# All other runtime assets resolve from the fixed WORKDIR above.
exec ./gophish --config "$runtime_config" "$@"
