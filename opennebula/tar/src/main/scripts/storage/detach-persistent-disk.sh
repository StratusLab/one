#!/bin/bash

ISCSIADM=/sbin/iscsiadm

DEVICE_LINK=$1

PORTAL_IP=134.158.75.2
PORTAL_PORT=3260
PORTAL="$PORTAL_IP:$PORTAL_PORT"

DIR=`dirname $DEVICE_LINK`

for i in $DIR/*.iscsi.uuid; do
  DISK=`cat $i`
  DETACH_CMD="$ISCSIADM --mode node --portal $PORTAL --targetname $DISK --logout"
  echo $DETACH_CMD
  $DETACH_CMD
done

