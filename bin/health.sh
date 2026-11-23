#!/bin/sh
# Deep health checks: each app's own backend must answer, not just the proxy.
#
# deploy.sh runs this after the smoke test, but a failure here is a warning,
# never a rollback: an upstream can be down for reasons no Caddy config change
# can fix. bin/smoke.sh stays the gate.
#
# SMOKE_TARGET overrides the address to probe (default: loopback on the host).
set -eu

TARGET="${SMOKE_TARGET:-127.0.0.1}"
MAX_TIME=10

fail=0

# check <host> <path> <expected-status>
check() {
	host=$1
	path=$2
	want=$3
	code=$(curl -ks -o /dev/null -w '%{http_code}' \
		--connect-timeout 5 --max-time "$MAX_TIME" \
		--resolve "$host:443:$TARGET" "https://$host$path" 2>/dev/null) || code=000
	if [ "$code" = "$want" ]; then
		printf '  %-32s %-18s %s\n' "$host" "$path" "$code"
	else
		printf '  %-32s %-18s %s (want %s) FAIL\n' "$host" "$path" "$code" "$want"
		fail=1
	fi
}

# The API health pages prove the upstream is serving, not merely that the
# static frontend (which smoke checks) is up.
check nohonu.com /api/health 200
check unrom.com /api/health 200
check stats.unrom.com /api/heartbeat 200
# The agent's API must reject anonymous callers; 200 here would mean auth is off.
check oc.metal.petermichon.fr /api/info 401

[ "$fail" -eq 0 ]
