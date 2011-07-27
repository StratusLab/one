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
STRATUS_POLICY=/etc/stratuslab/policy.cfg

get_vmdir

SRC_PATH=`arg_path $SRC`
DST_PATH=`arg_path $DST`

fix_paths

log_debug "$1 $2"
log_debug "DST: $DST_PATH"

DST_HOST=`arg_host $DST`
DST_DIR=`dirname $DST_PATH`

VM_DIR=$(dirname $(dirname $DST))
VM_ID=$(basename $VM_DIR)


log "Creating directory $DST_DIR"
exec_and_log "mkdir -p $DST_DIR"
exec_and_log "chmod ug+w,o-rwx $DST_DIR"

function _download_and_extract () {
    case $SRC in
    http://*.gz|https://*.gz)
        log "Downloading GZip archive $SRC"
        exec_and_log "download_and_extract $SRC $DST_PATH.gz $GUNZIP" \
            "Error downloading $SRC"
        ;;

    http://*.bz2|https://*.bz2)
        log "Downloading BZip2 archive $SRC"
        exec_and_log "download_and_extract $SRC $DST_PATH.bz2 $BUNZIP2" \
            "Error downloading $SRC"
        ;;

    http://*|https://)
        if [ -e "${STRATUS_POLICY}" ]; then
            exec_and_log "stratus-policy-image $SRC ${STRATUS_POLICY}"
        else
            error_message "Site policy isn't defined : ${STRATUS_POLICY} no such file or directory"
            exit -1
        fi
        LOCATION=$(stratus-manifest --get-element location $SRC)
        rc=$?
        if [ "$rc" == "0" ] && [ -n "$LOCATION" ]; then
            log "Image location from image manifest: $LOCATION"
            SRC=$LOCATION
            _download_and_extract
        else
            log "Downloading $SRC"
            exec_and_log "$CURL -k -o $DST_PATH $SRC" \
                "Error downloading $SRC"
        fi
        ;;

    pdisk:*)
        PORTAL=`echo $SRC | cut -d ':' -f 2`
        DISK_UUID=`echo $SRC | cut -d ':' -f 3`
        log "Persistent disk handling $SRC $DST"
        exec_and_log "$SSH -t -t $DST_HOST /usr/sbin/attach-persistent-disk.sh $SRC $DST_PATH" \
            "Failed to clone persistent disk $DST_PATH"
        exec_and_log "python /var/share/stratuslab/creation/pdisk-registrar.py -n $DST_HOST -u $DISK_UUID -p $PORTAL $VM_ID" \
           "Failed to write persistent disk properties"
        ;;

    *)
        log "Cloning $SRC_PATH"
        exec_and_log "cp -r $SRC_PATH $DST_PATH" \
            "Error copying $SRC to $DST"
        ;;
    esac
}

_download_and_extract

if [ -e $DST_PATH ] && [ ! -L $DST_PATH ]; then
  exec_and_log "chmod ug+rw,o-rwx $DST_PATH"
fi
