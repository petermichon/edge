#!/bin/sh
# Report a failed systemd unit through the monitor webhook.
#
# Used by OnFailure= in the edge-deploy unit. The app loop and the monitor send
# their own alerts; this covers a deploy that fails before it can say anything.
set -eu

unit=${1:-unknown}

# shellcheck source=/dev/null
[ -f /etc/edge/monitor.env ] && . /etc/edge/monitor.env
[ -n "${ALERT_WEBHOOK_URL:-}" ] || exit 0

msg="systemd unit $unit failed on $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
curl -fsS -m 10 -H "Title: edge alert" -d "$msg" "$ALERT_WEBHOOK_URL" >/dev/null || true
