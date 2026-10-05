# caddy:2 plus the OVH DNS provider, needed for the *.nohonu.com wildcard
# certificate (ACME DNS-01). Everything else uses Caddy's default HTTP-01.
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/ovh

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
