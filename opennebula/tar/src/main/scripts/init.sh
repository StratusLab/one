#!/bin/sh -e

CONTEXT_FILE=/mnt/stratuslab/context.sh

. $CONTEXT_FILE

mkdir -p /root/.ssh
echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys
chmod -R 600 /root/.ssh/

if [ -n "$SCRIPT_EXEC" ]; then
    VARS=`cat $CONTEXT_FILE | egrep -e '^[a-zA-Z\-\_0-9]*=' | sed 's/=.*$//'`
    for v in $VARS; do
      export $v
    done
    INIT_SCRIPT=/tmp/init_extra.sh
    echo $SCRIPT_EXEC > $INIT_SCRIPT
    sh $INIT_SCRIPT
fi
