#!/bin/bash

HOMEDIR="$1"
USER="$2"
GROUP="$3"
shift 3

[ -d "$HOMEDIR" ] || {
	umask 0022
	mkdir -p "$HOMEDIR"

	# by default only the user has access to his/her own home directory ...
	ACL="user::rwx,user:$USER:rwx,group::---,other::---,mask::rwx"
	# ... unless we were asked to add some admin groups, in which case
	# members of those groups have access to all home directories too
	for AG do
		ACL="$ACL,group:$AG:rwx"
	done

	chacl -b "$ACL" "$ACL" "$HOMEDIR"
	chown "$USER:$GROUP" "$HOMEDIR"
}
