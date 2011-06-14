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
SRC_PATH=`arg_path $SRC`
DST_PATH=`arg_path $DST`

SRC_HOST=`arg_host $SRC`
DST_HOST=`arg_host $DST`


log_debug "$1 $2"
log_debug "DST: $DST_PATH"

DST_DIR=`dirname $DST_PATH`

log "Creating directory $DST_DIR"
exec_and_log "$SSH $DST_HOST mkdir -p $DST_DIR" \
    "Error creating directory $DST_DIR"

function _download_and_extract () {
    case $SRC in
    http://*.gz|https://*.gz)
        log "Downloading GZip archive $SRC"
        exec_and_log "download_and_extract $SRC $DST_PATH.gz $GUNZIP $DST_HOST" \
            "Error downloading $SRC"
        ;;

    http://*.bz2|https://*.bz2)
        log "Downloading BZip2 archive $SRC"
        exec_and_log "download_and_extract $SRC $DST_PATH.bz2 $BUNZIP2 $DST_HOST" \
            "Error downloading $SRC"
        ;;

    http://*|https://)
        IMAGE_IDENTIFIER=$(stratus-manifest --get-element identifier $SRC)
        rc=$?
        if [ "$rc" == "0" ] && [ -n "${IMAGE_IDENTIFIER}" ]; then
            log "Image identifier from image manifest: ${IMAGE_IDENTIFIER}"
            if [ -e "${STRATUS_POLICY}" ]; then
                exec_and_log "stratus-policy-image ${IMAGE_IDENTIFIER} ${STRATUS_POLICY}"
            else
                error_message "Site policy isn't defined : ${STRATUS_POLICY} not such file or directory"
                exit -1
            fi
        else
            error_message "image identifier not found in $SRC"
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
            exec_and_log "$SSH $DST_HOST $CURL -k -o $DST_PATH $SRC" \
                "Error downloading $SRC"
        fi
        ;;

    pdisk:*)
        log "Persistent disk handling $SRC $DST"
        DST_HOST=`arg_host $DST`
        exec_and_log "$SSH -t -t $DST_HOST sudo /usr/sbin/attach-persistent-disk.sh $SRC $DST_PATH" \
            "Failed to create persistent disk $DST_PATH"
        ;;

    *)
        log "Cloning $SRC"
        exec_and_log "$SCP $SRC $DST" "Error copying $SRC to $DST"
        ;;
    esac
}

_download_and_extract

if [ ! -L $DST_PATH ]; then
  exec_and_log "$SSH $DST_HOST chmod --quiet ug+w,o-rwx $DST_PATH"
fi

