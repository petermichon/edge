#!/bin/sh
# Deploy the edge on the host.
#
# Reload when the Caddy config changed, recreate when the image or compose file
# did, health-gated either way. Anything that fails validation or the smoke
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

# A change to the Caddy config needs a reload; a change to the image or the
# compose file needs a recreate. Treat them as independent: a commit that
# touches both sites/ and, say, bin/ must still reload, and `docker compose
# up -d` is a no-op when only the config text changed.
reload_config=0
rebuild=0
container_changed=0
for f in $changed; do
	case "$f" in
		Caddyfile|sites/*|snippets/*) reload_config=1 ;;
		Dockerfile) rebuild=1 ;;
		compose.yaml|compose.yml) container_changed=1 ;;
		*) ;;
	esac
done
# A missing container (first run, or after `down`) must be created, not reloaded.
docker compose ps -q caddy | grep -q . || container_changed=1

if [ "$rebuild" -eq 1 ]; then
	echo "==> building proxy image"
	docker compose build
fi

echo "==> validating"
./bin/validate.sh

apply() {
	if [ "$rebuild" -eq 1 ] || [ "$container_changed" -eq 1 ]; then
		docker compose up -d --wait
	elif [ "$reload_config" -eq 1 ]; then
		docker compose exec -T caddy caddy reload \
			--address 127.0.0.1:2019 \
			--config /etc/caddy/Caddyfile --adapter caddyfile
	fi
}

rollback() {
	echo "==> rolling back to $PREV" >&2
	git reset --hard --quiet "$PREV"
	if [ "$rebuild" -eq 1 ]; then
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
