#!/usr/bin/env python
#
# Copyright (c) 2013, SixSq Sarl
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

from stratuslab.tm.TMQuarantine import TMQuarantine

if __name__ == '__main__':
    try:
        tm = TMQuarantine(sys.argv)
        tm.run()
    except Exception, e:
        print >> sys.stderr, 'ERROR MESSAGE --8<------'
        print >> sys.stderr, '%s: %s' % (os.path.basename(__file__), e)
        print >> sys.stderr, 'ERROR MESSAGE ------>8--'
        if TMQuarantine.PRINT_TRACE_ON_ERROR: 
            raise
        sys.exit(1)
