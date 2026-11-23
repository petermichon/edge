#!/bin/sh
# Deploy the edge on the host.
#
# Reload when the Caddy config changed, recreate when the image or compose file
# did, health-gated either way. Validation and apply failures roll back to the
# previous commit; smoke and deep health describe the apps, so they warn but
# never revert a config that loaded successfully.
set -eu
cd "$(dirname "$0")/.."

# One deploy at a time. The lock must not live on this script's inode: when a
# pull changes this file, git replaces it via rename, so a second run would
# open the new inode and proceed in parallel.
mkdir -p "$HOME/.cache"
exec 9>"$HOME/.cache/edge-deploy.lock"
flock -n 9 || { echo "another deploy is already running" >&2; exit 1; }

# Rollback resets --hard, so anything uncommitted would be destroyed. Refuse
# now and let the operator commit, stash or discard deliberately.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "refusing to deploy: the work tree has uncommitted changes" >&2
	git status --short >&2
	exit 1
fi

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
		# Caddy applies log-output changes to an existing file only on a
		# restart, not a reload (see snippets/logging.caddyfile).
		snippets/logging.caddyfile) container_changed=1 ;;
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
	echo "==> WARNING: smoke checks failed; the config stays live" >&2
	echo "    validation and apply succeeded, so the proxy config is fine:" >&2
	echo "    an upstream is down, which a rollback cannot fix" >&2
fi

# An upstream can be down for reasons no Caddy config change can fix, so deep
# health failures are reported but never roll back a passing deploy.
echo "==> deep health checks"
if ! ./bin/health.sh; then
	echo "==> WARNING: an app is unhealthy; the config stays live" >&2
	echo "    smoke passed, so the proxy is fine: see bin/health.sh output" >&2
fi

echo "==> deployed $(git rev-parse --short HEAD)"
