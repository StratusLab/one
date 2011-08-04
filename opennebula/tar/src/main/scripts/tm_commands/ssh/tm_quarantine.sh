#!/bin/sh

# -------------------------------------------------------------------------- #
# Copyright 2011, Centre National de la Recherche Scientifique (CNRS)        #
#                                                                            #
# Created as part of the StratusLab project (http://stratuslab.eu),          #
# co-funded by the European Commission under the Grant Agreement             #
# INSFO-RI-261552."                                                          #
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

do_abort()
{
  if [ "${1}" -ne "0" ]; then
    log "ERROR: ${2}"
    exit ${1}
  fi
}

do_warn()
{
  if [ "${1}" -ne "0" ]; then
    log "WARNING: ${2}"
  fi
}

SRC=$1

if [ -z "${ONE_LOCATION}" ]; then
    TMCOMMON=/usr/lib/one/mads/tm_common.sh
else
    TMCOMMON=$ONE_LOCATION/lib/mads/tm_common.sh
fi

. $TMCOMMON

get_vmdir

SRC_PATH=`arg_path $SRC`
SRC_HOST=`arg_host $SRC`

# This appears to do exactly the wrong thing.
#fix_src_path

# Locate the quarantine directory.  Currently relative paths
# are use to locate this.  Essentially: $SRC_PATH/../../quarantine.
QUARANTINE_DIR=`dirname $SRC_PATH`
QUARANTINE_DIR=`dirname $QUARANTINE_DIR`
QUARANTINE_DIR=$QUARANTINE_DIR/quarantine

# Original directory with VM files.  Essentially: $SRC_PATH/../.
SRC_DIR=`dirname $SRC_PATH`

# Detach persistent disk
$SSH $SRC_HOST /usr/sbin/detach-persistent-disk.sh $SRC_DIR

# Log what is going to be done. 
log "info: beginning to move files to quarantine ($SRC_DIR, $QUARANTINE_DIR)" 

# Make the directory if necessary.
$SSH $SRC_HOST "mkdir -p $QUARANTINE_DIR"
do_abort $? "cannot create quarantine directory ($QUARANTINE_DIR)" 

# Change times for all files in original directory.
$SSH $SRC_HOST "find $SRC_DIR -exec touch {} \;"
do_warn $? "cannot touch all files in source directory ($SRC_DIR)" 

# Reduce the access rights in the directory.
$SSH SRC_HOST "chmod -R g-rwxs,o-rwx $SRC_DIR"
do_warn $? "cannot reduce access right for source files" 

# Move the directory into place. 
$SSH SRC_HOST "mv $SRC_DIR $QUARANTINE_DIR"
do_abort $? "cannot move files to quarantine ($SRC_DIR, $QUARANTINE_DIR)" 

# Log what is going to be done. 
log "info: successfully moved files to quarantine ($SRC_DIR, $QUARANTINE_DIR)" 

exit 0
