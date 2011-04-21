#!/bin/sh -e

. /mnt/stratuslab/context.sh

mkdir -p /root/.ssh
echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys
chmod -R 600 /root/.ssh/

if [ -n "$SCRIPT_EXEC" ]; then
    CONTEXT=$(mktemp)
    cp -f /mnt/stratuslab/context.sh $CONTEXT
    sed -i -e '/^[A-Z]*=/s|^|export |' $CONTEXT
    . $CONTEXT
    rm -f $CONTEXT
    INIT_SCRIPT=/tmp/init_extra.sh
    echo $SCRIPT_EXEC > $INIT_SCRIPT
    sh $INIT_SCRIPT
else
    touch /tmp/stratuslab-context-no-SCRIPT_EXEC
fi
