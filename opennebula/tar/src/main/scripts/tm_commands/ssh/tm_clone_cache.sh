#!/bin/bash

# -------------------------------------------------------------------------- #
# Copyright 2002-2011, OpenNebula Project Leads (OpenNebula.org)             #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

SRC=$1
DST=$2

if [ -z "${ONE_LOCATION}" ]; then
    TMCOMMON=/usr/lib/one/mads/tm_common.sh
else
    TMCOMMON=$ONE_LOCATION/lib/mads/tm_common.sh
fi

. $TMCOMMON

SRC_PATH=`arg_path $SRC`
DST_PATH=`arg_path $DST`

SRC_HOST=`arg_host $SRC`
DST_HOST=`arg_host $DST`

log "Applying policy on $SRC"
IMAGEID=${SRC##*/}

# Retrieve the first fully qualified validated MP identifier 
output=
exec_and_log "stratus-policy-image $SRC" "Failed policy validation" true
IDENTIFIER=$output

PDISKPORT=8445
export STRATUSLAB_PDISK_ENDPOINT=$(stratus-config persistent_disk_ip)

VGPATH=$(stratus-config persistent_disk_lvm_device)
TMPSTORE=/tmp

log "Get PDISK ID from cache."
# NB! search may return more than one PDISK ID as the tag in not unique!
PDISKID=$(stratus-storage-search tag $IMAGEID) 
if [ "$?" -eq "0" ];then 
    if [ -z "$PDISKID" ]; then
        log "Cache miss. Image $IMAGEID not cached."
        log "Download and cache it."

        IMAGELOCATION=$(stratus-manifest --get-element location $IDENTIFIER)

        # Critical section - start.
        # Image and its stored copy have to be deleted if something goes wrong.
        # See blow fo the end of the critical section.
        PDISKID=
        function onexit() {
            $SSH -t -t $STRATUSLAB_PDISK_ENDPOINT rm -f $IMAGE_LOCAL
            [ -n "$PDISKID" ] && stratus-storage-delete $PDISKID
        }
        trap onexit EXIT

        IMAGE_LOCAL=$TMPSTORE/$(date +%s).${IMAGELOCATION##*/}
        exec_and_log "$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT curl -o $IMAGE_LOCAL $IMAGELOCATION" \
            "Failed to download $IMAGELOCATION" true

        IMAGECOMPRESS=$(stratus-manifest --get-element compression $IDENTIFIER)
        uncompress=
        if [ "$IMAGECOMPRESS" = "gz" ];then 
            uncompress=/bin/gunzip
        elif [ "$IMAGECOMPRESS" = "bz2" ]; then
            uncompress=/bin/bunzip2 
        fi

        IMAGESIZE_b=$(stratus-manifest --get-element bytes $IDENTIFIER)
        IMAGEFORMAT=$(stratus-manifest --get-element format $IDENTIFIER)

        log "OK - IMAGEID: $IMAGEID. Location: $IMAGELOCATION. Compression: $IMAGECOMPRESS"
        log "Create logical volume for the new disk."
        
        if [[ $IMAGEFORMAT == qco* ]]; then
            if [ ! -z $uncompress ] ; then
                $uncompress $IMAGE_LOCAL
                IMAGE_LOCAL=${IMAGE_LOCAL%.*}
            fi
            IMAGESIZE_b=$(qemu-img info $IMAGE_LOCAL | awk '/virtual size/ {sub(/\(/,""); print $4}' )
        elif [ "$IMAGEFORMAT" = "raw" ]; then
            if [ "$IMAGECOMPRESS" = "bz2" ]; then
                IMAGESIZE_b=$(bzcat $IMAGE_LOCAL | wc -c)
            elif [ "$IMAGECOMPRESS" = "gz" ]; then
                #IMAGESIZE_b=$(gunzip -l $IMAGE_LOCAL | tail -1 | awk '{print $2}')

                #PART_INFO=$(zcat $IMAGE_LOCAL | file -)
                #IMAGESIZE_b=$(echo $PART_INFO | awk ... 

                IMAGESIZE_b=$IMAGESIZE_b
            fi 
        fi

        #IMAGESIZE_G=$(echo "scale=3; $IMAGESIZE_b/1024^3" | bc)
        IMAGESIZE_G=$(echo "$IMAGESIZE_b/1024^3 + 1" | bc)

        # This new LV should never be shared by iSCSI server.
        PDISKID=$(stratus-storage -s $IMAGESIZE_G | cut -d' ' -f 2)

        if [[ $IMAGEFORMAT == qco* ]]; then
            # qcow image can be put on LV as is w/o conversion to raw. Test this.
            # Though this probably will not work with create-image.
            exec_and_log "$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT sudo qemu-img convert -O raw $IMAGE_LOCAL $VGPATH/$PDISKID" \
                "Failed to convert qcow image to raw." true
        else
            exec_and_log "$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT sh -c \"$uncompress -c $IMAGE_LOCAL | sudo /bin/dd of=$VGPATH/$PDISKID bs=2048\"" \
                "Failed to uncompress the image to Logical Volume" true
        fi

        trap - EXIT
        # Critical section - end.

        # Define tag the base image
        exec_and_log "stratus-storage-update $PDISKID tag $IMAGEID" \
             "Failed updating tag for $PDISKID disk" true
    fi
else
    log "Failed to get PDISK ID for image id: $IMAGEID"
    exit 1
fi
log "PDISK ID $PDISKID for IMAGEID $IMAGEID"

# Critical section - start.
# Delete COW snapshot on any failure.
PDISKID_COW=
function onexit() {
    [ -n "$PDISKID_COW" ] && stratus-storage-delete $PDISKID_COW
}
trap onexit EXIT

log "Requesting snapshot disk of the origin: $PDISKID"
output=
exec_and_log "stratus-storage --cow $PDISKID -t $IMAGEID" \
    "Failed to create snapshot of origin $PDISKID" true
PDISKID_COW=$(echo $output | cut -d' ' -f 2)
# Define tag for the snapshot as the above -t doesn't work
exec_and_log "stratus-storage-update $PDISKID_COW tag snapshot:$PDISKID" \
     "Failed updating the disk storage" true
log "Snapshot disk created: $PDISKID_COW"

INSTANCEID=$(basename $(dirname $(dirname $DST_PATH)))
log "Get instance owner."
USER=$(onevm list | awk '/^[ \t]*'$INSTANCEID' / {print $2}')
exec_and_log "stratus-storage-update $PDISKID_COW owner $USER" \
     "Failed updating the disk storage" true

exec_and_log "stratus-storage-update $PDISKID isreadonly true" \
     "Failed updating the disk storage" true

PDISKID_COW_URL=pdisk:$STRATUSLAB_PDISK_ENDPOINT:$PDISKPORT:$PDISKID_COW

DST_DIR=`dirname $DST_PATH`

log "creating directory $DST_DIR"
exec_and_log "$SSH -t -t $DST_HOST mkdir -p $DST_DIR" \
    "error creating directory $DST_DIR" true

log "Persistent disk handling $PDISKID_COW_URL $DST"
exec_and_log "$SSH -t -t $DST_HOST /usr/sbin/attach-persistent-disk.sh $PDISKID_COW_URL $DST_PATH" \
    "Failed to attach persistent disk $DST_PATH" true

trap - EXIT
# Critical section - end.

if [ ! -L $DST_PATH ]; then
  exec_and_log "$SSH -t -t $DST_HOST sudo chmod --quiet ug+w,o-rwx $DST_PATH" true
fi
