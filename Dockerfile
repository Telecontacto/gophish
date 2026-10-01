FROM golang:1.26.8-bookworm AS builder

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -mod=readonly -trimpath -ldflags="-s -w" -o /out/gophish .

FROM debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates jq gosu tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /opt/gophish
COPY --from=builder /out/gophish ./gophish
COPY VERSION LICENSE config.json ./
COPY db/db_sqlite3/ ./db/db_sqlite3/
COPY templates/ ./templates/
COPY static/js/dist/ ./static/js/dist/
COPY static/js/src/vendor/ckeditor/ ./static/js/src/vendor/ckeditor/
COPY static/css/dist/ ./static/css/dist/
COPY static/images/ ./static/images/
COPY static/font/ ./static/font/
COPY static/db/ ./static/db/
COPY static/endpoint/ ./static/endpoint/
COPY docker/run.sh /usr/local/bin/gophish-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/gophish-entrypoint \
    && chmod 755 /usr/local/bin/gophish-entrypoint

# The entrypoint briefly runs as root to initialize mounted-volume permissions,
# then execs the application as UID/GID 10001 (no privileged ports required).
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/gophish-entrypoint"]
