# Deployment source of truth

Status: **target design, not current deployment.**

This repository currently owns the shared Caddy proxy and its access/report
tooling. The application stacks are still deployed from separate directories on
the host. The goal is for `edge` to own the deployment manifests for the whole
host so a new server can be brought up from this repository plus secrets.

Application source code stays in the application repositories. `edge` owns only
the deployment layer:

- public hostnames and Caddy configuration
- TLS and the shared `edge` network
- image tags/digests
- service definitions, ports, volumes and restart policy
- deployment, rollback, backup and retention jobs
- secret templates (never real secret values)

## Current inventory

| Stack     | Current location      | Services                       | Persistent data                                                                 | Secrets                                      |
| --------- | --------------------- | ------------------------------ | ------------------------------------------------------------------------------- | -------------------------------------------- |
| Caddy     | `/srv/edge`           | `caddy`, `goaccess`            | `edge_caddy-data`, `edge_caddy-config`, `edge_access-logs`, `edge_stats-report` | `/etc/edge/edge.env`, `/etc/edge/stats-auth` |
| Umami     | `/srv/umami` (no git) | `umami`, `db`                  | `umami_db-data`                                                                 | `/srv/umami/.env`                            |
| unrom     | `/srv/unrom`          | `unrom-api`, `unrom-web`       | none                                                                            | none                                         |
| nohonu    | `/srv/nohonu`         | `nohonu-backend`, `nohonu-web` | `nohonu_nohonu_data`                                                            | not yet inventoried                          |
| veodee    | `/srv/veodee`         | `veodee`                       | none                                                                            | not yet inventoried                          |
| namecada  | `/srv/namecada`       | `namecada`                     | none                                                                            | none                                         |
| platformer| `/home/debian/git/platformer` | `platformer-web`       | none                                                                            | none                                         |
| freshdock | per-app stacks        | `freshdock`                    | Docker socket                                                                   | none                                         |
| opencode  | host process (systemd, documented in `docs/opencode.md`) | `opencode serve` | `~/.local/share/opencode` (sessions, provider auth) | `/etc/opencode/server.env` |

`/etc/systemd/system` also holds `umami-retention.timer` and an unversioned
`umami-backup.timer`; neither is installed from this repository yet.

Two live deltas are easy to miss. `/srv/unrom/deploy/compose.override.yaml` is
untracked and carries the `edge` aliases plus the bundled-Caddy disable, so the
unrom repository alone cannot reproduce the live route. And `platformer` runs
from `/home/debian/git/platformer`, not `/srv`.

### One updater per host

`freshdock` watches every labelled container on the Docker daemon, not only the
project that started it. Four per-stack instances were running at once; their
logs show repeated `409 name already in use` and `404 No such container` as
they raced, and an interrupted recreate left `nohonu-backend` created but never
started for six days. Keep exactly one instance per host, and drop the
per-stack `freshdock` service as each app moves into this repository.

All application services join the external `edge` network. Only Caddy publishes
ports `80` and `443`; the `127.0.0.1:3000`/`:3001` binds on unrom are debugging
fallbacks, not required by the proxy. `opencode` is the exception: it runs on
the host and the proxy reaches it on the bridge gateway, scoped by ufw — see
[`opencode.md`](opencode.md).

Umami retention is versioned here under `stacks/umami/`, but the running host
still uses copies in `/srv/umami` and `/etc/systemd/system`.

## Target layout

```text
edge/
  compose.yaml
  stacks/
    caddy/compose.yaml
    umami/compose.yaml
    unrom/compose.yaml
    nohonu/compose.yaml
    veodee/compose.yaml
    namecada/compose.yaml
    platformer/compose.yaml
  docs/deployment.md
  bin/bootstrap.sh
  bin/deploy.sh
  bin/health.sh
  bin/backup.sh
  .env.example
```

Root compose:

```yaml
name: edge
include:
  - stacks/caddy/compose.yaml
  - stacks/umami/compose.yaml
  - stacks/unrom/compose.yaml
  - stacks/nohonu/compose.yaml
  - stacks/veodee/compose.yaml
```

`bootstrap.sh` should:

1. check Docker/Compose
2. create the external `edge` network
3. create `/etc/edge` and install `.env.example` files
4. install the Umami retention timer
5. validate the compose files

`deploy.sh` should:

1. refuse to run on a dirty work tree
2. `git pull --ff-only`
3. validate (`bin/validate.sh`, which runs `docker compose config`)
4. pull or build changed images
5. `docker compose up -d --wait`
6. run the existing smoke test
7. run `bin/health.sh` (report only, never a rollback gate)
8. roll back to the previous commit on validation, apply or smoke failure

## Deferred, higher-friction work

Do these only with a backup and a tested restore path:

- [ ] Move the Umami compose file into `stacks/umami/compose.yaml`.
- [ ] Copy/adapt the unrom compose file into `stacks/unrom/compose.yaml`,
      including the untracked `compose.override.yaml` (edge aliases, bundled
      Caddy disabled). Version that override in the unrom repository now, so a
      clean redeploy cannot silently break routing.
- [ ] Inventory nohonu and veodee compose files, environment keys and volumes.
- [ ] Keep one `freshdock` instance per host instead of one per stack; four
      raced and left a container created but never started.
- [ ] Version `umami-backup` next to the retention job.
- [ ] Preserve existing volume names explicitly (`umami_db-data`,
      `nohonu_nohonu_data`, `edge_*`) so a project rename does not orphan data.
- [ ] Move app secrets to `/etc/edge/<stack>.env` with `.env.example` templates.
- [ ] Pin production images by digest, not floating tags, and document the bump
      process.
- [ ] Decide where freshdock belongs; it currently runs once per stack.
- [ ] Move retention from hand-installed systemd units to either a versioned
      installer or a Compose sidecar.
- [ ] Add `bootstrap.sh`, `backup.sh` and a restore procedure.
- [ ] Test the whole stack on a throwaway host before touching production.
- [ ] Migrate the live host without losing named volumes.
- [ ] Remove the old `/srv/<app>` stacks after a successful cutover.

## Cutover risks

- A changed Compose project name changes anonymous/default volume names.
- App secrets are not all known yet.
- Some app stacks use their own default networks as well as `edge`; removing
  those networks can break inter-service DNS.
- Caddy service names and aliases are part of the proxy contract.
- Image tags such as `latest` are not reproducible; moving to digests changes
  the update workflow.
- `freshdock` has a writable Docker socket and must not be duplicated.
