#!/bin/sh -e

source /mnt/context.sh

mkdir -p /root/.ssh
echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys
chmod -R 600 /root/.ssh/

exit 0

