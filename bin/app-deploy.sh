#!/bin/sh
# Deploy merged changes and updated images for the stateless app stacks.
#
# Runs from edge-apps.timer every five minutes as debian. This is a normal host
# script using the docker CLI, not a container with the Docker socket mounted.
# Stateful stacks (nohonu, umami) are deliberately excluded: their upgrades can
# migrate data and stay manual.
#
# If an apply fails, the script retags the previous images, rolls the compose
# commit back, and freezes the stack. A frozen stack is skipped until its
# freeze file is removed, so a bad :latest does not retry every five minutes.
set -eu

# Alert through the same ntfy/webhook as the monitor.
# shellcheck source=/dev/null
[ -f /etc/edge/monitor.env ] && . /etc/edge/monitor.env

FREEZE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/edge-apps"
mkdir -p "$FREEZE_DIR"

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
	freeze="$FREEZE_DIR/frozen-$name"

	if [ -f "$freeze" ]; then
		echo "==> $name frozen: $(cat "$freeze")"
		return
	fi

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

	# Remember what is running now, so a failed apply can be rolled back even
	# when the change was an image-only :latest update.
	state=$(mktemp -d)
	docker compose "$@" ps -q 2>/dev/null | while read -r id; do
		[ -n "$id" ] || continue
		ref=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null || true)
		img=$(docker inspect -f '{{.Image}}' "$id" 2>/dev/null || true)
		if [ -n "$ref" ] && [ -n "$img" ]; then
			printf '%s %s\n' "$ref" "$img" >>"$state/images"
		fi
	done

	if ! docker compose "$@" pull >/dev/null; then
		echo "image pull failed for $name" >&2
		alert "edge apps: image pull failed for $name on $(hostname)"
		rm -rf "$state"
		fail=1
		return
	fi

	if docker compose "$@" up -d --wait --wait-timeout 180; then
		rm -rf "$state"
		return
	fi

	echo "apply failed for $name; restoring the previous images" >&2
	if [ -n "$prev" ]; then
		git -C "$dir" reset --hard --quiet "$prev" || true
	fi
	if [ -f "$state/images" ]; then
		while read -r ref img; do
			case "$ref" in
				*@*) ;;
				*) docker tag "$img" "$ref" >/dev/null 2>&1 || echo "could not retag $ref" >&2 ;;
			esac
		done <"$state/images"
	fi
	docker compose "$@" up -d --wait --wait-timeout 180 || true
	rm -rf "$state"

	printf 'apply failed at %s; previous images restored\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$freeze"
	alert "edge apps: $name unhealthy on $(hostname); rolled back and frozen. Fix, then rm $freeze"
	fail=1
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
