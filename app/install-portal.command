#!/bin/sh
set -eux
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -x "$resources/portal" ] || [ ! -x "$resources/portald" ]; then
    echo "The bundled portal executable is missing. Reinstall Portal." >&2
    exit 1
fi

printf 'Installing portal and portald in /usr/local/bin.\nEnter your administrator password if prompted.\n'
/usr/bin/sudo /bin/mkdir -p /usr/local/bin
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 755 "$resources/portal" /usr/local/bin/portal
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 755 "$resources/portald" /usr/local/bin/portald
/usr/bin/sudo /bin/rm -f /usr/local/bin/gitinuum /usr/local/bin/gitinuumd
printf '\nInstalled /usr/local/bin/portal and /usr/local/bin/portald. You can close this window.\n'
