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

CONFIG=/etc/stratuslab/quarantine.cfg
COMMAND=/usr/sbin/tmpwatch
LOCATION=/var/lib/one/quarantine
PERIOD=48

if [ -e "$CONFIG" ]; then
  . $CONFIG
fi

if [ ! -x "$COMMAND" ]; then
  echo "$COMMAND not found or not executable"
  exit 1
fi

if [ ! -d "$LOCATION" ]; then
  echo "$LOCATION is not an existing directory"
  exit 1
fi

$COMMAND -mf $PERIOD $LOCATION 2>&1
