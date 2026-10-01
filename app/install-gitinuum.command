#!/bin/sh
set -eux
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -x "$resources/gitinuum" ]; then
    echo "The bundled gitinuum executable is missing. Reinstall Portal." >&2
    exit 1
fi

printf 'Installing gitinuum in /usr/local/bin.\nEnter your administrator password if prompted.\n'
/usr/bin/sudo /bin/mkdir -p /usr/local/bin
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 755 "$resources/gitinuum" /usr/local/bin/gitinuum
printf '\nInstalled /usr/local/bin/gitinuum. You can close this window.\n'
