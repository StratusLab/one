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

INSTANCEID=$(basename $(dirname $(dirname $DST_PATH)))

PDISKPORT=8445
export STRATUSLAB_PDISK_ENDPOINT=$(stratus-config persistent_disk_ip)

function start_from_cow_snapshot() {

    log "Applying policy on $SRC"
    IMAGEID=${SRC##*/}
    
    # Retrieve the first fully qualified validated MP identifier 
    output=
    exec_and_log "stratus-policy-image $IMAGEID" "Failed policy validation" true
    IDENTIFIER=$output
    
    VGPATH=$(stratus-config persistent_disk_lvm_device)

    TMPSTORE=$(stratus-config persistent_disk_temp_store) || TMPSTORE=/tmp
    mkdir -p $TMPSTORE

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
            # See below for the end of the critical section.
            PDISKID=
            function onexit() {
                $SSH -t -t $STRATUSLAB_PDISK_ENDPOINT rm -f ${IMAGE_LOCAL}*
                [ -n "$PDISKID" ] && stratus-storage-delete $PDISKID
            }
            trap onexit EXIT
    
            IMAGE_LOCAL=$TMPSTORE/$(date +%s).${IMAGELOCATION##*/}
            exec_and_log "$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT curl -o $IMAGE_LOCAL $IMAGELOCATION" \
                "Failed to download $IMAGELOCATION" true
    
            set -e
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
   
            set +e
 
            # This new LV should never be shared by iSCSI server.
            output=
            exec_and_log "stratus-storage -s $IMAGESIZE_G" \
                "Failed to create disk of size $IMAGESIZE_G GB in PDISK server." true
            PDISKID=$(echo $output | cut -d' ' -f 2)

            CHECKSUM=sha1
            CHECKSUM_CMD=${CHECKSUM}sum

            output=
            exec_and_log "stratus-manifest --get-element $CHECKSUM $IDENTIFIER" \
                "Failed to get $CHECKSUM from manifest of $IDENTIFIER" true
            CHECKSUM_VAL=$output

            CHECKSUM_FILE="${IMAGE_LOCAL}.$CHECKSUM"
            echo "$CHECKSUM_VAL  -" > $CHECKSUM_FILE
 
            if [[ $IMAGEFORMAT == qco* ]]; then
                exec_and_log "$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT sh -c \"cat $IMAGE_LOCAL | $CHECKSUM_CMD -c $CHECKSUM_FILE\"" \
                    "Image $CHECKSUM checksum check failed." true
                exec_and_log "$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT sh -c \"cp -f $IMAGE_LOCAL $VGPATH/$PDISKID\"" \
                    "Failed to write qcow image to Logical Volume" true
            else
                if [ -z "$uncompress" ] ; then
                    exec_and_log "$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT sh -c \"cat $IMAGE_LOCAL | $CHECKSUM_CMD -c $CHECKSUM_FILE\"" \
                        "Image $CHECKSUM checksum check failed." true
                    exec_and_log "$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT sh -c \"dd if=$IMAGE_LOCAL of=$VGPATH/$PDISKID bs=2048\"" \
                        "Failed to write the image to Logical Volume" true
                else 
                    exec_and_log "$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT sh -c \"$uncompress -c $IMAGE_LOCAL | $CHECKSUM_CMD -c $CHECKSUM_FILE\"" \
                        "Image $CHECKSUM checksum check failed." true
                    exec_and_log "$SSH -t -t $STRATUSLAB_PDISK_ENDPOINT sh -c \"$uncompress -c $IMAGE_LOCAL | dd of=$VGPATH/$PDISKID bs=2048\"" \
                        "Failed to uncompress the image to Logical Volume" true
                fi
            fi

            trap - EXIT
            # Critical section - end.
    
            # Define tag for the base image (origin)
            exec_and_log "stratus-storage-update $PDISKID tag $IMAGEID" \
                 "Failed updating tag for $PDISKID disk" true

            exec_and_log "stratus-storage-update $PDISKID isreadonly true" \
                 "Failed updating the disk storage" true

            $SSH -t -t $STRATUSLAB_PDISK_ENDPOINT rm -f $IMAGE_LOCAL || true
        else
            # Sanitize in case of multiple results.
            PDISKID=${PDISKID%% *}
            n="
"
            PDISKID=${PDISKID%%${n}*}
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
    
    set -e
    
    log "Requesting snapshot disk of the origin: $PDISKID"
    output=
    exec_and_log "stratus-storage --cow $PDISKID -t $IMAGEID" \
        "Failed to create snapshot of origin $PDISKID" true
    PDISKID_COW=$(echo $output | cut -d' ' -f 2)
    # Define tag for the snapshot as the above -t doesn't work
    exec_and_log "stratus-storage-update $PDISKID_COW tag snapshot:$PDISKID" \
         "Failed updating the disk storage" true
    log "Snapshot disk created: $PDISKID_COW"
    
    log "Get instance owner."
    USER=$(onevm list | awk '/^[ \t]*'$INSTANCEID' / {print $2}')
    exec_and_log "stratus-storage-update $PDISKID_COW owner $USER" \
         "Failed updating the disk storage" true
    
    PDISKID_COW_URL=pdisk:$STRATUSLAB_PDISK_ENDPOINT:$PDISKPORT:$PDISKID_COW
    
    DST_DIR=`dirname $DST_PATH`
    
    log "creating directory $DST_DIR"
    exec_and_log "$SSH -t -t $DST_HOST mkdir -p $DST_DIR" \
        "error creating directory $DST_DIR" true
    
    log "Persistent disk handling $PDISKID_COW_URL $DST"
    exec_and_log "$SSH -t -t $DST_HOST /usr/sbin/attach-persistent-disk.sh $PDISKID_COW_URL $DST_PATH" \
        "Failed to attach persistent disk $DST_PATH" true
    
    set +e
    
    trap - EXIT
    # Critical section - end.
}

function start_from_persisted() {
    INSTANCEID=$(basename $(dirname $(dirname $DST_PATH)))
    USER=$(onevm list | awk '/^[ \t]*'$INSTANCEID'/ {print $2}')
    PASS=$(awk -F= '/'$USER'/, sub(/\,.*/,"") {print $2; exit}' /etc/stratuslab/authn/login-pswd.properties)

    UUID=${SRC##*:}
    COW_FALSE=$(stratus-storage-search --pdisk-username $USER --pdisk-password $PASS iscow false)
    READONLY_FALSE=$(stratus-storage-search --pdisk-username $USER --pdisk-password $PASS isreadonly false)
    if ( echo $COW_FALSE | grep -q $UUID ) && ( echo $READONLY_FALSE | grep -q $UUID ); then
        DST_DIR=`dirname $DST_PATH`
        log "creating directory $DST_DIR"
        exec_and_log "$SSH -t -t $DST_HOST mkdir -p $DST_DIR" \
            "error creating directory $DST_DIR" true

        log "Persistent disk handling $SRC $DST"
        exec_and_log "$SSH -t -t $DST_HOST /usr/sbin/attach-persistent-disk.sh $SRC $DST_PATH" \
            "Failed to clone persistent disk $DST_PATH"
    else
        exec_and_log "/bin/false" \
            "Failed booting from $SRC. Check that you are the owner of the disk, the disk is not readonly and not a snapshot."
    fi
}

case $SRC in
    pdisk:*)
        start_from_persisted
        ;; 
    *) 
        start_from_cow_snapshot
        ;;
esac

if [ ! -L $DST_PATH ]; then
  exec_and_log "$SSH -t -t $DST_HOST sudo /bin/chmod ug+w,o-rwx $DST_PATH" \
      "Failed to change mode of $DST_PATH" true
fi