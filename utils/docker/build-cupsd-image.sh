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
	IMAGENAME='fedora25/cupsd'
fi

IMAGEDIR='cupsd-imageroot'

BUILDROOT='/builddir'

BASEDIR="`dirname "$0"`"

set -x

BUILDROOT="$BUILDROOT" "$BASEDIR/run-fedora-contianer.sh" \
	"$BUILDROOT/create-cupsd-image.sh" "$BUILDROOT/$IMAGEDIR"

"$BASEDIR/import-cupsd-image.sh" "$BASEDIR/$IMAGEDIR" "$IMAGENAME"
