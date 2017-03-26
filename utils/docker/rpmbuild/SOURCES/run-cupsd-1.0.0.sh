#!/bin/sh
/usr/sbin/portrelease cups
exec /usr/sbin/cupsd -f < /dev/null > /dev/null 2>&1
