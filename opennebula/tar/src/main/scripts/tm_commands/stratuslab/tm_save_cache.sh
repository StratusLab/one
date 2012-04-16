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

do_abort()
{
  if [ "${1}" -ne "0" ]; then
    log "ERROR: ${2}"
    exit ${1}
  fi
}

SRC_PATH=`arg_path $SRC`
DST_PATH=`arg_path $DST`

SRC_HOST=`arg_host $SRC`
DST_HOST=`arg_host $DST`

DST_DIR=`dirname $DST_PATH`

set -e

# Check if we were called to create an image.
INSTANCEID=$(basename $(dirname $(dirname $SRC_PATH)))
CREATE_IMAGE=$(onevm show $INSTANCEID 2>/dev/null | awk '/CREATE_IMAGE/,/\]/' 2>/dev/null)

# Find a way to source this from somewhere.
PDISKPORT=8445
export STRATUSLAB_PDISK_ENDPOINT=$(stratus-config persistent_disk_ip)

VGDIR=$(stratus-config persistent_disk_lvm_device)
VG=$(basename $VGDIR)

# Rocover PDISK ID of disk.0 assuming SRC_PATH is in a form /path/ID/images/disk.X
VM_DIR=$(dirname $(dirname $SRC_PATH))
PDISK_INFO=$($SSH -q -t -t $SRC_HOST "source /etc/stratuslab/pdisk-host.cfg; head -1 $VM_DIR/\$REGISTER_FILENAME")
# SSH adds carriage return
PDISK_INFO=$(echo $PDISK_INFO | tr -d '\r')
PDISKID_DISK0=${PDISK_INFO##*:}
PDISK_SERVICE_HOSTPORT=$(echo $PDISK_INFO|awk -F: '{print $2":"$3}')

# Detach disks from VM
$SSH -t -t $SRC_HOST /usr/sbin/detach-persistent-disk.sh $VM_DIR

SNAPSHOT_FILE=$VGDIR/$PDISKID_DISK0
SNAPSHOT_LV=$VG/$PDISKID_DISK0

# Calculate IMAGE ID and define it as TAG for create-volume.
SHA1=$($SSH -q -t -t $STRATUSLAB_PDISK_ENDPOINT sha1sum ${SNAPSHOT_FILE} | cut -d' ' -f1)
IMAGEID=$(python -c "import sys
sys.path.append('/var/lib/stratuslab/python/')
from stratuslab.ManifestInfo import ManifestIdentifier
print ManifestIdentifier().sha1ToIdentifier('$SHA1')")

log "Requesting rebase of the snapshot: $PDISKID_DISK0"
output=
exec_and_log "stratus-storage --rebase $PDISKID_DISK0" \
    "Failed to rebase the snapshot $PDISKID_DISK0" true 
PDISKID_NEW=$(echo $output | cut -d' ' -f 2)
exec_and_log "stratus-storage-update $PDISKID_NEW identifier $IMAGEID" \
    "Failed to update identifier on $PDISKID_NEW with $IMAGEID" true

## Build manifest for new image.
function onexit() {
    rm -rf ${P12CERT} ${MANIFEST_DIR}
}
trap onexit EXIT

P12CERT=$(mktemp --tmpdir=$HOME --suffix=.p12 certXXXX)
P12PASS=$RANDOM
P12VALID=2
exec_and_log "stratus-generate-p12 --output $P12CERT --validity $P12VALID --password $P12PASS" \
    "Failed to generate P12 certificate for signing metadata" true

# Checksum new image. Create and sign manifest. 
MANIFEST_DIR=$HOME/manifest$(date +%s)
mkdir -p $MANIFEST_DIR
MANIFEST_FILE=$MANIFEST_DIR/manifest.xml
MANIFEST_FILE_NOTSIGNED=$MANIFEST_DIR/manifest-not-signed.xml

ORIGIN_IMAGEID_URL=$(onevm show $INSTANCEID|awk '/DISK_ID=0/,/]/'|awk -F= '/SOURCE/, sub(/\,/,"") {print $2}')
ORIGIN_IMAGEID=${ORIGIN_IMAGEID_URL##*/}

# NB! Requires: the following attributes. Should be provided via ONE deployment script.
#CREATOR_EMAIL=
#CREATOR_NAME=
#NEWIMAGE_VERSION=
#NEWIMAGE_COMMENT=
#NEWIMAGE_MARKETPLACE=
# Optinal attributes
#MSG_TYPE=
#MSG_ENDPOINT=
#MSG_QUEUE=
#MSG_MESSAGE=
MANIFEST_INFO_VARS=$MANIFEST_DIR/manifest_info_vars.sh
onevm show $INSTANCEID | awk '/CREATE_IMAGE/,/\]/' | \
    sed 's/,$//g;s/\]//g;s/CREATE_IMAGE.*//;s/^[ \t]*//;/^$/d' | \
    awk -F= '{printf "%s=%s\n", $1, $2}'  > $MANIFEST_INFO_VARS
source $MANIFEST_INFO_VARS
VARS=`cat $MANIFEST_INFO_VARS | egrep -e '^[A-Z]*=' | sed 's/=.*$//'`
for v in $VARS; do
  export $v
done

# Define target Markteplace with the following order of precedence: 
#  1. defined by user in CREATE_IMAGE
#  2. defined in stratuslab.cfg by site admin as marketplace_endpoint_local
#  3. same as of origin if full Marketplace ID URL was provided as source 
MARKETPLACE_TARGET=
if [ -n "$NEWIMAGE_MARKETPLACE" ]; then
    MARKETPLACE_TARGET=$NEWIMAGE_MARKETPLACE
else

    MARKETPLACE_TARGET=$(stratus-config marketplace_endpoint_local 2>/dev/null || true)

    if [ -z "$MARKETPLACE_TARGET" ]; then
    	
	    case $ORIGIN_IMAGEID_URL in
	    http://*) # started with full Marketplace ID URL
                 MARKETPLACE_TARGET=$(echo $ORIGIN_IMAGEID_URL | awk -F/ '{print $1"/"$2"/"$3}')
	             ;;
	           *) # otherwise, take the local Marketplace endpoint
	             MARKETPLACE_TARGET=$(stratus-config marketplace_endpoint_local 2>/dev/null || true)
	             ;;
	    esac
    fi
fi
[ -z "$MARKETPLACE_TARGET" ] && \
    do_abort 1 "Target Marketplace for new image manifest registration was not provided."

IMAGE_VALIDITY_HOURS=$(( 24 * $P12VALID ))

PDISK_INFO_NEW="${PDISK_INFO%:*}:${PDISKID_NEW}"

NOT_SET=""
python -c "import sys, os
sys.path.append('/var/lib/stratuslab/python/')
from stratuslab.Creator import Creator
from stratuslab.ConfigHolder import ConfigHolder
from stratuslab.ManifestInfo import ManifestInfo
ManifestInfo.IMAGE_VALIDITY = int('$IMAGE_VALIDITY_HOURS') * 3600
ch = ConfigHolder()
ch.username='foo'
ch.password='bar'
ch.endpoint='baz'
ch.verboseLevel = '3'
ch.p12Certificate = '$P12CERT'
ch.p12Password = '$P12PASS'
c = Creator('$ORIGIN_IMAGEID', ConfigHolder())
c._retrieveManifest()
for chksum, val in Creator.checksumImageLocal('$PDISKID_NEW_FILE', ['md5','sha256','sha512']).items():
    c.checksums[chksum]['sum'] = val
c.checksums['sha1']['sum'] = '$SHA1'
c.author = '${CREATOR_NAME-$NOT_SET}'
c.newImageGroupVersion = '${NEWIMAGE_VERSION-$NOT_SET}'
c.comment = '${NEWIMAGE_COMMENT-$NOT_SET}'
c.manifestObject = c._updateManifest()
c.manifestObject.locations = ['$PDISK_INFO_NEW']
c.manifest = c.manifestObject.tostring()
c._saveManifest()
os.system('mv %s %s' % (c.manifestLocalFileName, '$MANIFEST_FILE'))
c.manifestLocalFileName = '$MANIFEST_FILE'
c._signManifest()"

# Give a nicer name to origianl manifest.
cp -f ${MANIFEST_FILE}.orig $MANIFEST_FILE_NOTSIGNED

# Upload manifest to MarketPlace
stratus-upload-metadata --marketplace-endpoint=$MARKETPLACE_TARGET $MANIFEST_FILE

# Send email to user
if [ -n "$CREATOR_EMAIL" ]; then
    EMAIL_TEXT="\n
Image creation was successful.\n
New image was stored in local PDISK service\n
https://$PDISK_SERVICE_HOSTPORT/cert/disks/$PDISKID_NEW\n
https://$PDISK_SERVICE_HOSTPORT/pswd/disks/$PDISKID_NEW\n
Image manifest with ID $IMAGEID was signed with dummy certificate and uploaded to $ORIGIN_MARKETPLACE.\n
Alternatively, you can sign attached manifest and upload to Marketplace with:\n
stratus-sign-metadata <manifest file>\n
stratus-upload-metadata <manifest file>\n
\n
NB! The validity of the manifest is $IMAGE_VALIDITY_HOURS hours. Please change it!\n
\n
The validity of the signing certificate is $P12VALID days.\n
\n
Cheers.\n"
    
    REPLY_TO_EMAIL=$(stratus-config save_image_reply_to_email)
    if [ "$?" != "0" ]; then
        REPLY_TO_EMAIL="noreply@stratuslab.eu"
    fi
    
    echo -e $EMAIL_TEXT | mail -s "New image created $IMAGEID." -a $MANIFEST_FILE_NOTSIGNED -r $REPLY_TO_EMAIL $CREATOR_EMAIL
else
    log "Fatal: Couldn't send email to the image creator. Creator email was not provided."
fi

if [ -n "$MSG_TYPE" ] && [ -n "$(which stratus-msg-publisher)" ] ; then
	log "Publishing message $MSG_MESSAGE to $MSG_TYPE:$MSG_ENDPOINT:$MSG_QUEUE"
	stratus-msg-publisher --msg-type $MSG_TYPE \
	                      --msg-endpoint $MSG_ENDPOINT \
	                      --msg-queue $MSG_QUEUE \
	                      --imageid $IMAGEID \
						  $MSG_MESSAGE
fi

log "MARKETPLACE_AND_IMAGEID $ORIGIN_MARKETPLACE $IMAGEID"
