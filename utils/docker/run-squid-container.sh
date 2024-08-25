#!/bin/bash

: "${IMAGENAME:=alpine-squid:3.8}"

if [ $# -gt 0 ]; then
	set -- \
		--tty \
		--interactive \
		"$IMAGENAME" \
		"$@"
else
	set -- \
		--name='squid' \
		--detach \
		--restart=always \
		"$IMAGENAME"
fi

exec docker run \
	--volume='/etc/squid:/etc/squid:ro' \
	--volume='/var/log/squid:/var/log/squid' \
	--network=host \
	"$@"
