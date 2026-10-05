#!/bin/sh
# Validate the Caddyfile and the compose file. Used locally, by deploy, and by CI.
set -eu
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-edge-caddy}"

# The config uses the OVH DNS provider, so validation needs the built image.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "building $IMAGE for validation" >&2
	docker build -t "$IMAGE" .
fi

docker run --rm \
	-v "$PWD":/etc/caddy:ro \
	"$IMAGE" \
	caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

docker compose config -q
