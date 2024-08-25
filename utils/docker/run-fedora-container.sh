#!/bin/bash

BASEDIR="`dirname "$0"`"

[ -n "$BUILDROOT" ] || BUILDROOT='/builddir'

[ $# -gt 0 ] || set -- /bin/bash

set -x

CONTAINER_ID="$(
	docker create \
		--volume="`readlink -f "$BASEDIR"`":"$BUILDROOT" \
		--net=host \
		--tty \
		--interactive \
		fedora \
		"$@"
)"

docker start --interactive "$CONTAINER_ID"

docker rm "$CONTAINER_ID"
