#!/bin/bash -xe

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
IDENTIFIER=$(stratus-policy-image $SRC)

PDISKPORT=8445
export STRATUSLAB_PDISK_ENDPOINT=`stratus-config persistent_disk_ip`

VG=vg.01
VGPATH=/dev/$VG
TMPSTORE=/tmp

log "Get PDISK ID from cache."
# NB! there are cases when describe-volumes returns more than one PDISK ID!
PDISKID=$(stratus-storage-search tag $IMAGEID) 
if [ "$?" -eq "0" ];then 
    if [ -z "$PDISKID" ]; then
        log "Cache miss. Image $IMAGEID not cached."
        log "Download and cache it."

        IMAGELOCATION=$(stratus-manifest --get-element location $IDENTIFIER)

        IMAGE_LOCAL=$TMPSTORE/$(date +%s).${IMAGELOCATION##*/}
        $SSH -t -t $STRATUSLAB_PDISK_ENDPOINT curl -o $IMAGE_LOCAL $IMAGELOCATION

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
        PDISKID=$(stratus-storage -s $IMAGESIZE_G -t $IMAGEID | cut -d' ' -f 2)
        # Define tag the base image as the above one -t doesn't work
        exec_and_log "stratus-storage-update $PDISKID tag $IMAGEID" \
             "Failed updating tag for $PDISKID disk"

        # this should go.
        sudo chmod 777 $VGPATH/$PDISKID

        if [[ $IMAGEFORMAT == qco* ]]; then
            # qcow image can be put on LV as is w/o conversion to raw. Test this.
            # Though this probably will not work with create-image.
            $SSH -t -t $STRATUSLAB_PDISK_ENDPOINT sudo qemu-img convert -O raw $IMAGE_LOCAL $VGPATH/$PDISKID
        else
            #$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT sudo sh -c "$uncompress -c $IMAGE_LOCAL > $VGPATH/$PDISKID"
            sudo sh -c "$uncompress -c $IMAGE_LOCAL > $VGPATH/$PDISKID"
        fi

        rm -f $IMAGE_LOCAL
    fi
else
    log "Failed to get PDISK ID for image id: $IMAGEID"
    exit 1
fi
log "PDISK ID $PDISKID for IMAGEID $IMAGEID"

log "Requesting snapshot disk of the origin: $PDISKID"
output=$(stratus-storage --cow $PDISKID -t $IMAGEID)
[ "$?" != "0" ] && exit 1
PDISKID_COW=$(echo $output | cut -d' ' -f 2)
# Define tag for the snapshot as the above -t doesn't work
exec_and_log "stratus-storage-update $PDISKID_COW tag snapshot:$PDISKID" \
     "Failed updating the disk storage"
log "Snapshot disk created: $PDISKID_COW"

INSTANCEID=$(basename $(dirname $(dirname $DST_PATH)))
USER=$(onevm list | awk '/one-'$INSTANCEID'/ {print $2}')
exec_and_log "stratus-storage-update $PDISKID_COW owner $USER" \
     "Failed updating the disk storage"

exec_and_log "stratus-storage-update $PDISKID isreadonly true" \
     "Failed updating the disk storage"

PDISKID_COW_URL=pdisk:$STRATUSLAB_PDISK_ENDPOINT:$PDISKPORT:$PDISKID_COW

log_debug "$1 $2"
log_debug "DST: $DST_PATH"

DST_DIR=`dirname $DST_PATH`

log "creating directory $DST_DIR"
$SSH $DST_HOST ls -al $DST_DIR/.. || true
exec_and_log "$SSH -t -t $DST_HOST mkdir -p $DST_DIR" \
    "error creating directory $DST_DIR"

log "Persistent disk handling $PDISKID_COW_URL $DST"
exec_and_log "$SSH -t -t $DST_HOST /usr/sbin/attach-persistent-disk.sh $PDISKID_COW_URL $DST_PATH" \
    "Failed to attach persistent disk $DST_PATH"

if [ ! -L $DST_PATH ]; then
  exec_and_log "$SSH -t -t $DST_HOST sudo chmod --quiet ug+w,o-rwx $DST_PATH"
fi
