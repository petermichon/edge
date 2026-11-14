# edge — shared reverse proxy

Caddy is the single entry point for this host. It owns `:80`/`:443`, terminates
TLS automatically (Let's Encrypt), and routes by hostname.

```
                    :80 / :443
                        │
              ┌─────────▼──────────┐
              │   edge (Caddy)     │
              │   network: edge    │
              └─┬─────┬─────┬────┬─┘
                │     │     │    │
  nohonu.com ───┘     │     │    └── stats.unrom.com → umami:3000
  *.nohonu.com        │     │
  custom domains      │     └─────── veodee.com → veodee:80
                      └───────────── unrom.com → unrom-web:3001
                                                 unrom-api:3000
```

Each app currently runs in its own repo and stack and joins the external `edge`
network. The apps do not know about each other; only this proxy knows them all.

## Deployment source of truth

This repository is the intended source of truth for the whole host deployment,
not just Caddy. That is not true yet: the application stacks are still deployed
from `/srv/<app>` separately.

The target layout, current inventory, migration checklist and known risks are
in [`docs/deployment.md`](docs/deployment.md). The Umami retention job is now
versioned under [`stacks/umami/`](stacks/umami/), but the live host still uses
its hand-installed copies.

## Current routes

| Hostname          | Upstream                                                      |
| ----------------- | ------------------------------------------------------------- |
| `nohonu.com`      | `/api/*` → `nohonu-backend:8080`, else `nohonu-web:80`        |
| `www.nohonu.com`  | 301 → `nohonu.com`                                            |
| `*.nohonu.com`    | `nohonu-backend:8080` (wildcard cert, DNS-01 via OVH)         |
| custom domains    | `nohonu-backend:8080` (on-demand cert, gated by the backend)  |
| `unrom.com`       | `/api` and `/api/*` → `unrom-api:3000`, else `unrom-web:3001` |
| `www.unrom.com`   | 301 → `unrom.com`                                             |
| `veodee.com`      | `veodee:80`                                                   |
| `www.veodee.com`  | 301 → `veodee.com`                                            |
| `stats.unrom.com` | `umami:3000` (`noindex`)                                      |
| `logs.unrom.com`  | static `stats-report` volume, basic auth (`noindex`)          |

Which hostname belongs to which tenant is decided by the nohonu backend from
the `Host` header. The proxy only maps names to services.

## Layout

```
Caddyfile              global options + imports
Dockerfile             caddy:2 pinned by digest, built with the OVH DNS plugin
compose.yaml           the Caddy service (project name: edge)
sites/<app>.caddyfile  one site block per app
snippets/*.caddyfile   shared snippets, imported into every site
stacks/umami/          versioned Umami retention job (not deployed from here yet)
docs/deployment.md     target host deployment model and migration checklist
bin/deploy.sh          pull, validate, reload-or-recreate, smoke, rollback
bin/validate.sh        Caddyfile + compose validation (used by deploy)
bin/smoke.sh           every public host must answer over HTTPS
.env.example           OVH credentials template (never commit real values)
```

`Caddyfile` imports everything in `snippets/` then everything in `sites/`, so
adding a file is the whole change.

## Host prerequisites

- Docker Engine + Compose v2.24 or newer (the compose file uses
  `env_file: required: false`).
- The shared network, created once per host:

  ```sh
  docker network create edge
  ```

- OVH API credentials for the `*.nohonu.com` wildcard certificate, stored
  outside the repo with mode 600:

  ```sh
  sudo install -D -m 600 -o "$USER" -g "$(id -gn)" .env.example /etc/edge/edge.env
  # then fill in OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, OVH_CONSUMER_KEY
  ```

  The file is optional in `compose.yaml`: without it the stack still starts,
  but the wildcard certificate cannot be issued or renewed.

## Deploy

```sh
bin/deploy.sh
```

The script is safe to run repeatedly and safe to interrupt, but never runs two
deploys at once (it takes a `flock`). What it does:

1. `git pull --ff-only` and stops if nothing changed.
2. If every changed file is under `sites/`, `snippets/`, or is the `Caddyfile`
   itself, and the container is running, it reloads in place: zero downtime,
   connections drained over the 10s grace period.
3. Otherwise it rebuilds only if the `Dockerfile` changed, then
   `docker compose up -d --wait`.
4. Validates first (`bin/validate.sh`); on any validation, apply, or smoke
   failure it resets to the previous commit and re-applies it.

Manual equivalents:

```sh
bin/validate.sh                     # run before merging
docker compose up -d                # first run, or after compose/Dockerfile changes
bin/smoke.sh                        # after any change
SMOKE_TARGET=203.0.113.10 bin/smoke.sh   # probe a remote host instead of loopback
```

Docs-only changes take the recreate path but `docker compose up -d` is a no-op
when the config hash is unchanged, so the container is not restarted.

## Adding an app

1. Create `sites/<app>.caddyfile` with a site block that `reverse_proxy`s the
   app's **service name and container port** — not a host port.
2. Add every new public hostname to `HOSTS` in `bin/smoke.sh`.
3. Point the domain's DNS at this host; Caddy provisions the certificate.
4. `bin/deploy.sh`.

The app stack joins the network as external, and needs no host ports:

```yaml
networks:
  edge:
    external: true
    name: edge
```

A `127.0.0.1:PORT` bind is redundant once the service is on `edge`, and it can
hide routing mistakes.

## Adding a host

```sh
git clone https://github.com/petermichon/edge.git /srv/edge
cd /srv/edge
docker network create edge
sudo install -D -m 600 -o "$USER" -g "$(id -gn)" .env.example /etc/edge/edge.env
$EDITOR /etc/edge/edge.env
# Report password for logs.unrom.com (see "Traffic logs")
docker run --rm -it caddy:2 caddy hash-password | sudo tee /etc/edge/stats-auth >/dev/null
sudo chmod 600 /etc/edge/stats-auth
docker compose up -d --build
bin/smoke.sh
```

Then add each app's stack on the same host and point DNS at it. Hosts are
independent: there is no shared state between them beyond DNS.

## Operations

```sh
docker compose ps                    # health of the proxy
docker logs -f edge-caddy-1          # Caddy's stdout/stderr
docker compose exec caddy caddy reload --address 127.0.0.1:2019 \
  --config /etc/caddy/Caddyfile --adapter caddyfile
```

- The admin API listens on `127.0.0.1:2019` **inside the container**, so it is
  reachable from Caddy's own network namespace only, not from apps or the host.
- Certificates and ACME state live in the `caddy-data` volume; the `caddy-config`
  volume holds runtime config. Both survive recreates.
- The healthcheck queries the admin API, so a config that loads but wedges the
  server shows as unhealthy.
- Caddy needs `:80` for ACME HTTP-01 and redirects; keep it open even though
  every site is HTTPS-only.

## Traffic logs

Caddy writes no access log unless a site asks for one, so `snippets/logging.caddyfile`
is imported per site as `import logging <name>`. Each site gets its own
`/var/log/caddy/<name>.log`: JSON, one line per request, nothing sampled or
filtered (query strings excepted — they are dropped so tokens never hit disk).

- **Coverage.** Platform hostnames only: `unrom`, `nohonu`, `veodee`. The
  `*.nohonu.com` block and the `https://` catch-all serve other people's sites,
  and `stats.unrom.com` would duplicate Umami's own data, so they are excluded.
- **Retention.** 30 days, by age (`roll_keep_for 720h`), not by file count.
  Rolled files are bounded by `roll_size 100MiB`.
- **Why both numbers exist.** Umami only sees clients that run JavaScript, so
  non-JS bots are invisible and headless browsers count as humans. The access
  log is the complete request stream; the two numbers are never summed.

The report is generated, not live:

```sh
docker compose --profile stats up -d          # start the report generator
docker compose logs -f goaccess               # parse errors land here
```

`goaccess` runs `--log-format=CADDY` over `/logs/*.log` every five minutes and
writes `index.html` to the `stats-report` volume, which Caddy serves at
`logs.unrom.com` behind basic auth.

- Country and ASN panels stay empty until MaxMind databases are mounted; add
  `GeoLite2-City.mmdb` / `GeoLite2-ASN.mmdb` and pass `--geoip-database`.
- Before deploying, point DNS for `logs.unrom.com` at this host (Caddy needs a
  certificate for the smoke test) and create `/etc/edge/stats-auth` with a hash
  from `caddy hash-password`.
- The file must be **root-owned**, mode 600. The container drops
  `CAP_DAC_OVERRIDE`, so root inside it cannot read a file owned by another
  user (`open ...: permission denied`).
- **Rotating the password takes a recreate, not a reload.** `{file.*}` is
  resolved when the config is provisioned, and a reload of a byte-identical
  config does not re-provision, so the old hash keeps working. Use
  `docker compose up -d --wait --force-recreate caddy` (a few seconds).
- Adding or removing a site's log file takes effect on reload. Changing the
  rolling options of an existing file requires a restart, so prefer the
  recreate path for those edits.

## Security posture

- Container is `read_only`, `cap_drop: ALL` + `NET_BIND_SERVICE`,
  `no-new-privileges`, with only `Caddyfile`, `sites/`, `snippets/` and the
  report volume mounted read-only. It never sees `.git` or `.env`. The single
  writable mount is `access-logs` (`/var/log/caddy`).
- Secrets come from `/etc/edge/edge.env` (mode 600, outside the repo).
- `security_headers` sends HSTS with `includeSubDomains` for platform-owned
  hostnames.
- `customer_headers` deliberately omits HSTS: we must not make an irreversible
  HTTPS-only commitment on a domain we do not own.
- Custom domains get certificates on demand, and only after the backend
  approves the name via `on_demand_tls` `ask`, so the proxy cannot be made to
  mint certificates for arbitrary domains.

## Conventions

- One site per file. No cross-site logic; if two sites need the same response
  headers, add a snippet.
- `handle /api/*` preserves the prefix; `handle_path /api/*` strips it. These
  are not interchangeable — check what the upstream expects before copying a
  site block.
- `handle /api/*` does not match bare `/api`. When an app serves an index at
  the bare path, use an explicit matcher such as `@api path /api /api/*`.
- A hostname that is not in `bin/smoke.sh` is not monitored by deploys.
- `.env` and `*.log` are gitignored; never add credentials or generated files.
