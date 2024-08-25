#!/bin/bash

if [ $# -gt 1 ]; then
	ARGS=''
	for P; do
		[ -z "$ARGS" ] || ARGS="$ARGS,"
		ARGS="$ARGS <$P>"
	done
	echo "Expected zero or one argumet - the image name, got:$ARGS" >&2
	exit 1
fi

if [ $# -gt 0 ]; then
	IMAGENAME="$1"
else
	IMAGENAME='alpine-squid:3.8'
fi

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

docker build --network=host --tag="$IMAGENAME" "$SCRIPT_DIR/squid"
