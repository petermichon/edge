#!/bin/sh
# Liveness smoke test: every public host must answer over HTTPS.
# SMOKE_TARGET overrides the address to probe (default: loopback on the host).
set -eu

HOSTS="nohonu.com unrom.com veodee.com stats.unrom.com logs.unrom.com"
TARGET="${SMOKE_TARGET:-127.0.0.1}"

fail=0
for host in $HOSTS; do
	code=$(curl -ks -o /dev/null -w '%{http_code}' \
		--resolve "$host:443:$TARGET" "https://$host/" || echo 000)
	# logs.unrom.com is behind basic auth, so 401 is its healthy answer: TLS
	# negotiated and Caddy served the site. Everything else must be 2xx/3xx.
	ok=0
	case "$code" in
		2*|3*) ok=1 ;;
		401) [ "$host" = "logs.unrom.com" ] && ok=1 ;;
	esac
	if [ "$ok" -eq 1 ]; then
		printf '  %-16s %s\n' "$host" "$code"
	else
		printf '  %-16s %s FAIL\n' "$host" "$code"; fail=1
	fi
done

[ "$fail" -eq 0 ]
