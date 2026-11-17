# opencode

The coding agent on `metal`, published as `oc.metal.petermichon.fr`.

Status: **live, host process under systemd** — deliberately not a container on
`edge`. This is the one route in this repository whose upstream is not a
service name on the `edge` network, and the reason is in "Why not a container".

## Shape

```
phone / desktop app / TUI
        │  https, Basic auth (user "opencode")
        ▼
Caddy  oc.metal.petermichon.fr          sites/opencode.caddyfile
        │  reverse_proxy 172.20.0.1:4096
        ▼
host   opencode.service (systemd)       172.20.0.1:4096
        │
        └─ repos, tools, provider credentials, sessions
```

DNS: `*.metal.petermichon.fr` is a wildcard A record to this host's public IP,
so new names under `metal` need no DNS work. The certificate for `oc.metal` is
issued via HTTP-01 on first request; Caddy renews it.

## Why not a container

The agent needs the host's repositories and the host's toolchain, and it is the
thing that edits code, so putting it behind a bind mount bought nothing. The
trade-off is explicit: this vhost points at the bridge gateway, which is why
the ufw rule below exists. If it ever moves into a container on `edge`, delete
`172.20.0.1:4096` here in favour of `opencode:4096` and drop the ufw rule.

## Host pieces

`/etc/systemd/system/opencode.service`, enabled at boot:

```ini
[Unit]
Description=OpenCode server
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=debian
Group=debian
WorkingDirectory=/home/debian
EnvironmentFile=/etc/opencode/server.env
ExecStart=/home/debian/.opencode/bin/opencode serve --hostname 172.20.0.1 --port 4096 --print-logs
Restart=always
RestartSec=3
MemoryMax=24G

NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=full
ProtectHome=no
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
```

The sandbox matters: the agent runs arbitrary commands by design.
`NoNewPrivileges` is what stops it from using the account's `NOPASSWD` sudo,
and `ProtectSystem=full` keeps `/etc`, `/usr` and `/boot` read-only so a bad
command cannot brick boot or SSH. `/home` stays writable — that is the work.

Firewall, scoped to the edge bridge subnet only:

```sh
ufw allow from 172.20.0.0/16 to any port 4096 proto tcp comment 'opencode via edge proxy'
```

Two opencode processes on one SQLite database corrupt it, so the CLI's implicit
background service is disabled here:

```sh
opencode service set disabled true
```

## Secrets

`/etc/opencode/server.env`, `600 root`, one line:

```
OPENCODE_PASSWORD=…
```

Read by systemd, never by the repo, never in `ExecStart` (no `ps` leak).
`opencode auth import` puts provider credentials in the agent's own store under
`~/.local/share/opencode`, `600`.

Rotate:

```sh
NEW=$(openssl rand -hex 24)
sudo sed -i "s|^OPENCODE_PASSWORD=.*|OPENCODE_PASSWORD=$NEW|" /etc/opencode/server.env
sudo systemctl restart opencode
```

Rotation invalidates every paired client (app profiles, browser cookies).

## Connecting a client

Manual entry, which is what the app stores:

```
URL       https://oc.metal.petermichon.fr
Username  opencode
Password  the value in /etc/opencode/server.env
```

`opencode pair` refuses to run against a standalone server ("Pairing requires
the background service"), but the endpoint behind it is served here, so a
one-time link can be minted directly:

```sh
PW=$(sudo sed -n 's/^OPENCODE_PASSWORD=//p' /etc/opencode/server.env)
C=$(curl -s -X POST -u "opencode:$PW" https://oc.metal.petermichon.fr/api/pair | jq -r .code)
echo "https://oc.metal.petermichon.fr/auth/connect/$C"
```

Codes are single-use and expire in five minutes.

Desktop, over SSH instead of the public hostname:

```
Host metal
    LocalForward 4096 172.20.0.1:4096
```

then `OPENCODE_PASSWORD=… opencode --server http://127.0.0.1:4096`.

## Verifying

```sh
curl -s -o /dev/null -w '%{http_code}\n' -u "opencode:$PW" https://oc.metal.petermichon.fr/api/info   # 200
curl -s -o /dev/null -w '%{http_code}\n' https://oc.metal.petermichon.fr/api/info                       # 401
curl -s -o /dev/null -w '%{http_code}\n' http://<public-ip>:4096/api/info                               # timeout
systemd-analyze security opencode | tail -1                                                            # 4.3 OK
sudo ss -ltn | grep 4096                                                                               # 172.20.0.1:4096 only
```

## Known gaps

- **One secret gates a shell.** No rate limiting, no second factor, no
  per-device revocation beyond rotating the password. A required
  `X-OC-Key` header (the app supports custom headers) or an authenticated
  proxy in front would fix this.
- **The agent shares the account with `NOPASSWD: ALL` sudo.** Blocked today by
  `NoNewPrivileges`; a dedicated non-sudo user would remove the dependency on
  that single flag.
- **`/` serves the client shell unauthenticated.** The API is 401 without
  credentials; the login page being public is normal for a web client.
- **SSE and long tool calls** mean reloads and deploys should use Caddy's
  `grace_period` (already set globally) rather than restarting Caddy mid-run.
