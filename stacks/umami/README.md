# Umami

This directory will hold the Umami deployment when it is moved into `edge`.

Currently only the retention job is versioned here. The live stack is still at
`/srv/umami`, and its hand-installed copies are at:

- `/srv/umami/retention.sql`
- `/etc/systemd/system/umami-retention.service`
- `/etc/systemd/system/umami-retention.timer`

## Retention

The job deletes analytics rows older than 12 months. It must run against the
Umami PostgreSQL container.

When the stack is moved into `edge`, install the versioned units:

```sh
sudo install -m 644 stacks/umami/retention.sql \
  /srv/edge/stacks/umami/retention.sql
sudo install -m 644 stacks/umami/systemd/umami-retention.service \
  /etc/systemd/system/umami-retention.service
sudo install -m 644 stacks/umami/systemd/umami-retention.timer \
  /etc/systemd/system/umami-retention.timer
sudo systemctl daemon-reload
sudo systemctl enable --now umami-retention.timer
```

The units assume the repository is checked out at `/srv/edge`, the Docker
container is named `umami-db-1`, and the service runs as `debian`. Adjust those
for a different host.

Do not install these units until the Umami stack is actually deployed from
`edge`; the current live units use `/srv/umami/retention.sql`.
