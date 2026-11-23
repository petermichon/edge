#!/bin/sh
# Liveness smoke test: every public host must answer over HTTPS.
# SMOKE_TARGET overrides the address to probe (default: loopback on the host).
set -eu

HOSTS="nohonu.com www.nohonu.com unrom.com www.unrom.com veodee.com www.veodee.com namecada.com www.namecada.com stats.unrom.com logs.unrom.com oc.metal.petermichon.fr platformer.metal.petermichon.fr"
TARGET="${SMOKE_TARGET:-127.0.0.1}"

# A host added in this deploy has no certificate yet, so its first requests fail
# at the TLS handshake while Caddy finishes ACME. Retry only that case (000):
# a host that answers with a status code has a verdict already.
ATTEMPTS=10
WAIT=3

probe() {
	code=$(curl -ks -o /dev/null -w '%{http_code}' \
		--connect-timeout 5 --max-time 10 \
		--resolve "$1:443:$TARGET" "https://$1/" 2>/dev/null) || code=000
	echo "$code"
}

fail=0
for host in $HOSTS; do
	code=$(probe "$host")
	attempt=1
	while [ "$code" = "000" ] && [ "$attempt" -lt "$ATTEMPTS" ]; do
		sleep "$WAIT"
		code=$(probe "$host")
		attempt=$((attempt + 1))
	done
	# logs.unrom.com is behind basic auth, so 401 is its healthy answer: TLS
	# negotiated and Caddy served the site. Everything else must be 2xx/3xx.
	ok=0
	case "$code" in
		2*|3*) ok=1 ;;
		401) [ "$host" = "logs.unrom.com" ] && ok=1 ;;
	esac
	if [ "$ok" -eq 1 ]; then
		printf '  %-32s %s\n' "$host" "$code"
	else
		printf '  %-32s %s FAIL\n' "$host" "$code"; fail=1
	fi
done

[ "$fail" -eq 0 ]
