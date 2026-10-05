# caddy:2 plus the OVH DNS provider, needed for the *.nohonu.com wildcard
# certificate (ACME DNS-01). Everything else uses Caddy's default HTTP-01.
#
# Pinned by tag + digest so builds are reproducible and tamper-proof.
# Bump deliberately (Renovate PR + CI), never by floating.
FROM caddy:2.11.6-builder@sha256:f5b1a66449d305280e559dba0ab9f7ce9a2a14c527c79d7c6fb48abc8f895818 AS builder
RUN xcaddy build v2.11.6 \
	--with github.com/caddy-dns/ovh@v1.1.0

FROM caddy:2.11.6-alpine@sha256:d44355d3c2149dc580ce2cac735955d1c08d3d00882c30489c241aa51a5c10d9
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
