#!/bin/sh
# Deploy merged changes and updated images for the stateless app stacks.
#
# Runs from edge-apps.timer every five minutes as debian. This is a normal host
# script using the docker CLI, not a container with the Docker socket mounted.
# Stateful stacks (nohonu, umami) are deliberately excluded: their upgrades can
# migrate data and stay manual.
set -eu

# Alert through the same ntfy/webhook as the monitor.
# shellcheck source=/dev/null
[ -f /etc/edge/monitor.env ] && . /etc/edge/monitor.env

mkdir -p "$HOME/.cache"
exec 9>"$HOME/.cache/edge-apps.lock"
flock -n 9 || exit 0

fail=0

alert() {
	[ -n "${ALERT_WEBHOOK_URL:-}" ] || return 0
	curl -fsS -m 10 -H "Title: edge apps" -d "$1" "$ALERT_WEBHOOK_URL" >/dev/null || true
}

# stack <name> <repo-dir> <compose args...>
stack() {
	name=$1
	dir=$2
	shift 2

	echo "==> $name"
	if [ ! -d "$dir" ]; then
		echo "missing $dir" >&2
		fail=1
		return
	fi

	prev=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")
	if ! git -C "$dir" pull --ff-only --quiet; then
		echo "git pull failed for $name (dirty or diverged?)" >&2
		alert "edge apps: git pull failed for $name on $(hostname)"
		fail=1
		return
	fi

	if ! docker compose "$@" pull >/dev/null; then
		echo "image pull failed for $name" >&2
		alert "edge apps: image pull failed for $name on $(hostname)"
		fail=1
		return
	fi

	if docker compose "$@" up -d --wait --wait-timeout 180; then
		return
	fi

	echo "apply failed for $name; rolling back the compose change" >&2
	alert "edge apps: $name failed to become healthy on $(hostname), rolling back"
	fail=1
	if [ -n "$prev" ]; then
		git -C "$dir" reset --hard --quiet "$prev" || true
		docker compose "$@" pull >/dev/null 2>&1 || true
		docker compose "$@" up -d --wait --wait-timeout 180 || true
	fi
}

stack unrom /srv/unrom/deploy \
	-f /srv/unrom/deploy/compose.yaml \
	-f /srv/unrom/deploy/compose.override.yaml
stack namecada /srv/namecada/apps/site \
	-f /srv/namecada/apps/site/compose.yaml \
	-f /srv/namecada/apps/site/compose.override.yaml
stack veodee /srv/veodee/deploy \
	-f /srv/veodee/deploy/compose.yaml \
	-f /srv/veodee/deploy/compose.override.yaml

[ "$fail" -eq 0 ]
