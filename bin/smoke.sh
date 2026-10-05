#!/bin/sh
# Liveness smoke test: every public host must answer over HTTPS.
# SMOKE_TARGET overrides the address to probe (default: loopback on the host).
set -eu

HOSTS="nohonu.com unrom.com veodee.com"
TARGET="${SMOKE_TARGET:-127.0.0.1}"

fail=0
for host in $HOSTS; do
	code=$(curl -ks -o /dev/null -w '%{http_code}' \
		--resolve "$host:443:$TARGET" "https://$host/" || echo 000)
	case "$code" in
		2*|3*) printf '  %-16s %s\n' "$host" "$code" ;;
		*)     printf '  %-16s %s FAIL\n' "$host" "$code"; fail=1 ;;
	esac
done

[ "$fail" -eq 0 ]
