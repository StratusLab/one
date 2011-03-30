#!/bin/bash

ISCSIADM=/sbin/iscsiadm

UUID_URL=$1
DEVICE_LINK=$2
DEVICE_MARKER=$DEVICE_LINK.iscsi.uuid

PORTAL_IP=134.158.75.2
PORTAL_PORT=3260
PORTAL="$PORTAL_IP:$PORTAL_PORT"

DISK_PREFIX="iqn.2011-01.eu.stratuslab"
DISK_UUID=`echo $UUID_URL | cut -d : -f 2`
DISK="$DISK_PREFIX:$DISK_UUID"

DISK_PATH="/dev/disk/by-path/ip-$PORTAL-iscsi-$DISK-lun-0"

ATTACH_CMD="$ISCSIADM --mode node --portal $PORTAL --targetname $DISK --login"

echo $ATTACH_CMD
$ATTACH_CMD

LINK_CMD="ln -s $DISK_PATH $DEVICE_LINK"
echo $LINK_CMD
$LINK_CMD

echo $DISK > $DEVICE_MARKER
