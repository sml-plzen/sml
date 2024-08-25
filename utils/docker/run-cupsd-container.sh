#!/bin/bash

[ -n "$IMAGENAME" ] || IMAGENAME='fedora25/cupsd'

if [ $# -gt 0 ]; then
	set -- \
		--volume=/:/host \
		--tty \
		--interactive \
		"$IMAGENAME" \
		"$@"
else
	set -- \
		--name="cupsd" \
		--detach \
		--restart=always \
		"$IMAGENAME"
fi

exec docker run \
	--volume=/etc/passwd:/etc/passwd:ro \
	--volume=/etc/shadow:/etc/shadow:ro \
	--volume=/etc/group:/etc/group:ro \
	--volume=/etc/gshadow:/etc/gshadow:ro \
	--volume=/etc/cups-docker:/etc/cups \
	--volume=/var/run/cups-docker:/var/run/cups \
	--volume=/var/run/portreserve:/var/run/portreserve \
	--volume=/var/log/cups-docker:/var/log/cups \
	--volume=/var/spool/cups-docker:/var/spool/cups \
	--volume=/var/cache/cups-docker:/var/cache/cups \
	--net=host \
	"$@"
