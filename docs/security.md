# Security baseline

Status: applied on the live host on 2026-11-23. The host files are versioned
here and installed by hand; re-check them after a rebuild.

## Host

### SSH

`host/sshd/99-hardening.conf`:

- key-only: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`
- `PermitRootLogin no` — root's key is inert; use `debian` + sudo
- `X11Forwarding no`
- `AllowTcpForwarding local` — keeps the documented opencode `LocalForward`,
  drops remote forwards
- `MaxAuthTries 3`

```sh
sudo install -m 644 host/sshd/99-hardening.conf /etc/ssh/sshd_config.d/
sudo sshd -t && sudo systemctl reload ssh
```

### fail2ban

- `sshd`: Debian default, 3 failures / 5 min, 30 min ban.
- `opencode`: parses Caddy's JSON access log for `status:401`, 10 failures /
  10 min, 1 h ban. Docker DNATs 443 to the Caddy container, so an input-chain
  ban would never see the traffic; this action hooks `nftables` `forward` at
  priority -10 in its own `f2b-opencode` table.

```sh
sudo install -m 644 host/fail2ban/filter.d/caddy-opencode.conf /etc/fail2ban/filter.d/
sudo install -m 644 host/fail2ban/jail.d/opencode.conf /etc/fail2ban/jail.d/
sudo fail2ban-regex /var/lib/docker/volumes/edge_access-logs/_data/opencode.log \
  /etc/fail2ban/filter.d/caddy-opencode.conf
sudo fail2ban-client reload
sudo fail2ban-client status opencode
```

The jail reads `/var/lib/docker/volumes/edge_access-logs/_data/opencode.log`;
update the path if the Compose project or volume name changes. To prove the
ban path, ban a TEST-NET address and inspect the table, then unban:

```sh
sudo fail2ban-client set opencode banip 192.0.2.123
sudo nft list table inet f2b-opencode
sudo fail2ban-client set opencode unbanip 192.0.2.123
```

### Firewall and updates

- ufw: default deny incoming; 22/80/443 open; 4096 only from `172.20.0.0/16`.
- `unattended-upgrades` is enabled. Security updates were installed on
  2026-11-23; kernel 6.12.118 is installed.
- **Reboot pending.** A reboot drops every site and kills the opencode agent:
  schedule it, do not treat it as a no-op. Confirm with
  `test -f /var/run/reboot-required`.

## Proxy

- Caddy and GoAccess are pinned by digest. Renovate (`renovate.json`) opens
  digest-bump PRs, CI validates, and `edge-deploy.timer` applies a merge within
  five minutes. Caddy is the only public listener.
- Caddy runs read-only, `cap_drop: ALL` + `NET_BIND_SERVICE`,
  `no-new-privileges`; the admin API listens on `127.0.0.1:2019` inside the
  container; secrets live outside the repo and the mounted tree.
- TLS 1.2+ only (TLS 1.1 is rejected), HSTS, `nosniff`, referrer policy, and
  no `Server` header on platform hostnames. Customer domains deliberately get
  no HSTS.
- Custom domains are issued on demand only after the backend approves the
  name, so the proxy cannot be made to mint certificates for arbitrary hosts.
- Access logs drop query strings, and Caddy redacts `Authorization`, `Cookie`
  and `Set-Cookie` by default.

## Accepted by design

**opencode has full host access.** It runs as `debian`, which is in the
`docker` group and has `NOPASSWD: ALL` sudo. That is deliberate: the agent is
meant to edit and deploy the host, so its blast radius is host root, the OVH DNS
credentials and every app volume. Treat the public vhost as a root console, not
as a normal web app. What protects it is access control: TLS, a 48-character
Basic-auth password, and the fail2ban jail above. If the *exposure* ever needs
to shrink without reducing the agent's privileges, put the vhost behind
Tailscale/WireGuard or require the app's `X-OC-Key` header — both are
access-control changes, not privilege changes.

Reading `edge.env`, `/srv/umami/.env` and the Docker socket is part of this
same accepted access. Root-owning those files would not change the agent's
effective power while it remains in the `docker` group.

## App updates

`freshdock` was removed on 2026-11-23. The containers were deleted and each
stack's untracked `compose.override.yaml` disables its profile. Updates for the
stateless stacks (`unrom`, `namecada`, `veodee`) now come from
`systemd/edge-apps.timer` → `bin/app-deploy.sh`: a normal host script using the
docker CLI, with no container holding the Docker socket. It pulls the repo and
images, recreates health-gated, and alerts. A failed apply retags the previous
images, rolls the compose commit back, and freezes the stack until
`~/.cache/edge-apps/frozen-<stack>` is removed. `nohonu` and `umami` stay manual
because upgrades can migrate data.

## Known risks, ranked

1. **App images still track `:latest`.** `edge-apps.timer` applies whatever the
   registry tag points to, so app updates remain unreviewed and non-reproducible
   until the app repos are digest-pinned and Renovate-managed. The updater is
   now a trusted host script rather than a third-party socket holder, but the
   trust model is the same.
2. **`logs.unrom.com` 401s are outside fail2ban.** That site has no access log
   (it would duplicate the report), so its Basic auth is unthrottled. The
   report is low value; revisit if it starts getting hit.
3. **No CSP or `X-Frame-Options`.** HSTS, `nosniff` and the referrer policy are
   set. CSP is app-specific, and framing headers are unsafe to apply to
   customer domains.
4. **Reboot pending** for kernel 6.12.118 (see above).

## Verify

```sh
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|allowtcpforwarding|x11forwarding)'
sudo fail2ban-client status
sudo fail2ban-client status opencode
sudo nft list table inet f2b-opencode
sudo ufw status verbose
apt list --upgradable
test -f /var/run/reboot-required && echo reboot-pending
```
