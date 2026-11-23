#!/bin/sh
# Validate the Caddyfile and the compose file. Used locally and by deploy.
set -eu
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-edge-caddy}"
AUTH="${STATS_AUTH_FILE:-/etc/edge/stats-auth}"

# Caddy resolves {file.*} while loading the config and refuses to start without
# the report's basic-auth hash, so a missing file is a validation error rather
# than a reason to skip the mount. CI passes STATS_AUTH_FILE with a throwaway
# hash so validation does not need the real secret.
if [ ! -s "$AUTH" ]; then
	echo "$AUTH is missing or empty;" >&2
	echo "install the report password hash first (see README)" >&2
	exit 1
fi

# The config uses the OVH DNS provider, so validation needs the built image.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "building $IMAGE for validation" >&2
	docker build -t "$IMAGE" .
fi

# Mount only what the config reads, so validation never sees .git or .env.
docker run --rm \
	-v "$AUTH":/etc/edge/stats-auth:ro \
	-v "$PWD/Caddyfile":/etc/caddy/Caddyfile:ro \
	-v "$PWD/sites":/etc/caddy/sites:ro \
	-v "$PWD/snippets":/etc/caddy/snippets:ro \
	"$IMAGE" \
	caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

docker compose config -q
