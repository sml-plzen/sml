#!/bin/bash

BASEDIR="`dirname "$0"`"

if [ $# -lt 1 -o $# -gt 2 ]; then
	ARGS=''
	for P; do
		[ -z "$ARGS" ] || ARGS="$ARGS,"
		ARGS="$ARGS <$P>"
	done
	echo "Expected one or two argumets - the image root and the image name, got:$ARGS" >&2
	exit 1
fi

set -x

IMAGEID="$(
	( \
		cd "$1"; \
		find . -mindepth 1 -maxdepth 1 -printf '%P\0' | \
		tar -c --numeric-owner -f - --null --no-unquote -T - \
	) \
	| \
	docker import \
		-c 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
		-c 'CMD ["/usr/sbin/run-cupsd"]' \
		-
)"

NEWID="`od -N32 -An -tx1 -w32 -v /dev/urandom | sed -e 's/ //g'`"

docker save "$IMAGEID" \
| \
"$BASEDIR/filter-image-tar.py" "$IMAGEID" "$NEWID" \
	'comment' 'CUPS server container based on Fedora 25' \
	'author'  'Michal Růžička <michal.ruza@gmail.com>' \
| \
docker load

docker rmi "$IMAGEID"

[ $# -gt 1 ] && docker tag "$NEWID" "$2"
