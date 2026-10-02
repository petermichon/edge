# edge — shared reverse proxy

Caddy is the single entry point for this host. It owns `:80`/`:443`, terminates
TLS automatically (Let's Encrypt), and routes by hostname.

```
                 :80 / :443
                     │
           ┌─────────▼──────────┐
           │  edge (caddy)      │
           │  network: edge     │
           └───┬────────────┬───┘
               │            │
         unrom.com      veodee.com
               │            │
       unrom-web/api     veodee
        (own repo)      (own repo)
```

Each app runs in its own repo and container and joins the external `edge`
network. The apps do not know about each other; only this proxy knows both.

The `edge` network is created once on the host:

```sh
docker network create edge
```

## Layout

- `compose.yaml` — the Caddy service.
- `Caddyfile` — imports every file in `sites/`.
- `sites/<app>.caddy` — one site block per app.

## Deploy

```sh
docker compose up -d
```

The `edge` network is shared by this proxy and every app, which attach to it
with `external: true`.

## Adding an app

1. Create `sites/<app>.caddy` with a site block that `reverse_proxy`s the
   app's service name and port.
2. `docker compose up -d`.
3. Point the domain's DNS at this host; Caddy provisions the certificate.
