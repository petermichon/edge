#!/bin/sh
# Deploy the edge on the host.
#
# Config-only changes are applied with `caddy reload` (zero downtime). Image
# changes recreate the container. Anything that fails validation or the smoke
# test is rolled back to the previous commit.
set -eu
cd "$(dirname "$0")/.."

PREV="$(git rev-parse HEAD)"

echo "==> fetching"
git pull --ff-only

changed="$(git diff --name-only "$PREV" HEAD || true)"
[ -n "$changed" ] || { echo "already up to date"; exit 0; }

rebuild=0
if echo "$changed" | grep -qx 'Dockerfile'; then
	rebuild=1
fi

if [ "$rebuild" -eq 1 ]; then
	echo "==> building proxy image"
	docker compose build
fi

echo "==> validating"
./bin/validate.sh

apply() {
	if [ "$rebuild" -eq 1 ]; then
		docker compose up -d
	else
		docker compose exec -T caddy \
			caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
	fi
}

rollback() {
	echo "==> rolling back to $PREV" >&2
	git reset --hard --quiet "$PREV"
	if [ "$rebuild" -eq 1 ]; then
		docker compose build
		docker compose up -d
	else
		docker compose exec -T caddy \
			caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
	fi
}

if ! apply; then
	rollback
	exit 1
fi

echo "==> smoke test"
if ! ./bin/smoke.sh; then
	rollback
	exit 1
fi

echo "==> deployed $(git rev-parse --short HEAD)"
