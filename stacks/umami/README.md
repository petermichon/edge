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

When the stack is moved into `edge`, install the versioned units (the SQL file
is already in this repository and the unit reads it from `/srv/edge`):

```sh
sudo install -m 644 stacks/umami/systemd/umami-retention.service \
  /etc/systemd/system/umami-retention.service
sudo install -m 644 stacks/umami/systemd/umami-retention.timer \
  /etc/systemd/system/umami-retention.timer
sudo systemctl daemon-reload
sudo systemctl enable --now umami-retention.timer
```

The versioned unit targets the root `edge` project: `/srv/edge/stacks/umami`
and database container `edge-db-1`. The units installed on the live host still
use `/srv/umami` and `umami-db-1`, because the stack has not moved yet. Do not
install the versioned unit before the move.

The companion `umami-backup.timer` is still host-only and is not versioned here.
