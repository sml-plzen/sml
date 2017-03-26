#!/bin/bash

BASEDIR="`dirname "$0"`"

if [ $# -ne 1 ]; then
	ARGS=''
	for P; do
		[ -z "$ARGS" ] || ARGS="$ARGS,"
		ARGS="$ARGS <$P>"
	done
	echo "Expected one argumet - the image root dir, got:$ARGS" >&2
	exit 1
fi

IMAGEDIR="`readlink -f "$1"`"

if [ ! -d "$IMAGEDIR" ]; then
	mkdir "$IMAGEDIR"
	set -- install \
		cups-runner gutenprint-cups shared-mime-info
else
	set -- update
fi

set -x

dnf -y --nogpg --releasever=25 --repofrompath=rpmbuild,"$BASEDIR/rpmbuild/RPMS" --installroot="$IMAGEDIR" \
	--setopt=install_weak_deps=false "$@"

dnf --releasever=25 --installroot="$IMAGEDIR" clean all

ln -sf '../usr/share/zoneinfo/Europe/Prague' "$IMAGEDIR/etc/localtime"

rm -rf "$IMAGEDIR/dev" "$IMAGEDIR/proc"

rm -f "$IMAGEDIR/etc/passwd"* "$IMAGEDIR/etc/shadow"*
rm -f "$IMAGEDIR/etc/group"* "$IMAGEDIR/etc/gshadow"*

rm -rf "$IMAGEDIR/etc/cups/"*
rm -rf "$IMAGEDIR/var/run/cups/"*
rm -rf "$IMAGEDIR/var/spool/cups/"*
rm -rf "$IMAGEDIR/var/cache/cups/"*
rm -rf "$IMAGEDIR/var/log/cups/"*
