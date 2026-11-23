#!/bin/sh
# Scheduled monitor: smoke, deep upstream health and certificate expiry, with
# two ways to reach a human. Runs from edge-monitor.timer every five minutes.
#
# Config lives in /etc/edge/monitor.env (mode 600, owned by the service user);
# see monitor.env.example. Nothing here needs Docker or root.
#
# The on-host timer cannot notice a dead host or a broken network. Point
# MONITOR_PING_URL at a Healthchecks.io check and it alerts when pings stop.
set -eu

TARGET="${SMOKE_TARGET:-127.0.0.1}"

# shellcheck source=/dev/null
[ -f /etc/edge/monitor.env ] && . /etc/edge/monitor.env

CERT_DAYS="${MONITOR_CERT_DAYS:-14}"
report=""
fail=0

collect() {
	label=$1
	shift
	if ! out=$("$@" 2>&1); then
		fail=1
		report="${report}${report:+
}$label:
$out"
	fi
}

# Check the two ACME paths in use: plain HTTP-01 on the apex hosts. A renewal
# failure is shared by every certificate in the same store, so one of each is
# enough to catch the common failure.
cert_check() {
	host=$1
	if ! echo | timeout 10 openssl s_client -connect "$TARGET:443" \
		-servername "$host" 2>/dev/null \
		| openssl x509 -noout -checkend "$((CERT_DAYS * 86400))" >/dev/null 2>&1; then
		fail=1
		report="${report}${report:+
}certificate $host: missing, invalid, or expires within ${CERT_DAYS}d"
	fi
}

collect "smoke" ./bin/smoke.sh
collect "health" ./bin/health.sh
cert_check nohonu.com
cert_check unrom.com

if [ "$fail" -eq 0 ]; then
	echo "edge monitor: ok"
	if [ -n "${MONITOR_PING_URL:-}" ]; then
		curl -fsS -m 10 -o /dev/null "$MONITOR_PING_URL" || true
	fi
	exit 0
fi

echo "edge monitor: FAIL"
printf '%s\n' "$report"

msg="edge monitor: FAIL on $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ)
$report"

if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
	if ! curl -fsS -m 10 -H "Title: edge monitor" -d "$msg" \
		"$ALERT_WEBHOOK_URL" >/dev/null; then
		echo "monitor: failed to deliver the alert" >&2
	fi
else
	echo "monitor: no ALERT_WEBHOOK_URL configured in /etc/edge/monitor.env" >&2
fi

if [ -n "${MONITOR_PING_URL:-}" ]; then
	curl -fsS -m 10 -o /dev/null "${MONITOR_PING_URL}/fail" || true
fi

exit 1
