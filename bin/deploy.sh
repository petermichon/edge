#!/bin/sh
# Deploy the edge on the host.
#
# Reload when every change is pure config (zero downtime); otherwise recreate
# the container, health-gated. Anything that fails validation or the smoke test
# is rolled back to the previous commit.
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

# Reload only when every changed file is config we can load in place.
reload_only=1
dockerfile=0
for f in $changed; do
	case "$f" in
		Caddyfile|sites/*|snippets/*) ;;
		Dockerfile) dockerfile=1; reload_only=0 ;;
		*) reload_only=0 ;;
	esac
done
# A missing container (first run, or after `down`) must be created, not reloaded.
docker compose ps -q caddy | grep -q . || reload_only=0

if [ "$dockerfile" -eq 1 ]; then
	echo "==> building proxy image"
	docker compose build
fi

echo "==> validating"
./bin/validate.sh

apply() {
	if [ "$reload_only" -eq 1 ]; then
		docker compose exec -T caddy caddy reload \
			--address 127.0.0.1:2019 \
			--config /etc/caddy/Caddyfile --adapter caddyfile
	else
		docker compose up -d --wait
	fi
}

rollback() {
	echo "==> rolling back to $PREV" >&2
	git reset --hard --quiet "$PREV"
	if [ "$dockerfile" -eq 1 ]; then
		docker compose build
	fi
	apply
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
