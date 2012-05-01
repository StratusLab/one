#!/usr/bin/env python
#
# Created as part of the StratusLab project (http://stratuslab.eu),
# co-funded by the European Commission under the Grant Agreement
# INFSO-RI-261552."
#
# Copyright (c) 2012, SixSq Sarl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
import os
import sys

sys.path.append('/var/lib/stratuslab/python')

from stratuslab.tm.TMCloneCache import TMCloneCache

if __name__ == '__main__':
    try:
        tm = TMCloneCache(sys.argv)
        tm.run()
    except Exception, e:
        print >> sys.stderr, 'ERROR MESSAGE --8<------'
        print >> sys.stderr, '%s: %s' % (os.path.basename(__file__), e)
        print >> sys.stderr, 'ERROR MESSAGE ------>8--'
        if TMCloneCache.PRINT_TRACE_ON_ERROR: 
            raise
        sys.exit(1)
