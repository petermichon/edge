#!/bin/sh
# Deploy the edge on the host.
#
# Config-only changes are applied with `caddy reload` (zero downtime). Image
# changes recreate the container. Anything that fails validation or the smoke
# test is rolled back to the previous commit.
set -eu
cd "$(dirname "$0")/.."

# One deploy at a time.
exec 9<"$0"
flock -n 9 || { echo "another deploy is already running" >&2; exit 1; }

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
		docker compose up -d --wait
	else
		docker compose exec -T caddy \
			caddy reload --address 127.0.0.1:2019 --config /etc/caddy/Caddyfile --adapter caddyfile
	fi
}

rollback() {
	echo "==> rolling back to $PREV" >&2
	git reset --hard --quiet "$PREV"
	if [ "$rebuild" -eq 1 ]; then
		docker compose build
		docker compose up -d --wait
	else
		docker compose exec -T caddy \
			caddy reload --address 127.0.0.1:2019 --config /etc/caddy/Caddyfile --adapter caddyfile
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
