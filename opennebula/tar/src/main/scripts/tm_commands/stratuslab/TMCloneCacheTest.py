#
# Created as part of the StratusLab project (http://stratuslab.eu),
# co-funded by the European Commission under the Grant Agreement
# INFSO-RI-261552."
#
# Copyright (c) 2011, SixSq Sarl
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
from unittest import TestCase, main
from tm_clone_cache import TMCloneCache

class TMCloneCacheTest(TestCase):

    def assertNotRaises(self, excClass, callableObj, *args, **kwargs):
        '''Fail if an exception of class excClass is thrown
           by callableObj when invoked with arguments args and keyword
           arguments kwargs. If a different type of exception is
           thrown, it will not be caught, and the test case will be
           deemed to have suffered an error, exactly as for an
           unexpected exception.
        '''
        try:
            callableObj(*args, **kwargs)
        except excClass:
            if hasattr(excClass, '__name__'): excName = excClass.__name__
            else: excName = str(excClass)
            raise self.failureException, '%s raised' % excName
        else:
            return
    
    def setUp(self):
        self.tm = TMCloneCache([], config='stratuslab.cfg')
            
    def test_should_raise_for_too_few_args(self):
        self.tm.args = []
        self.assertRaises(ValueError, self.tm._checkArgs)
        
    def test_should_raise_for_too_many_args(self):
        self.tm.args = ['1', '2', '3', '4']
        self.assertRaises(ValueError, self.tm._checkArgs)
        
    def test_should_pass_for_expected_args(self):
        # Remember that python will provide at least the file name
        # Should get +2 args at call
        self.tm.args = ['1', '2', '3']
        self.assertNotRaises(ValueError, self.tm._checkArgs) 
        
    def test_should_return_disk_path_when_provided(self):
        arg = 'host-42:/the/path_xy.ext'
        self.assertEquals(self.tm._getDiskPath(arg), '/the/path_xy.ext')

    def test_should_return_disk_host_when_provided(self):
        arg = 'host-42:/the/path_xy.ext'
        self.assertEquals(self.tm._getDiskHost(arg), 'host-42')
    
    def test_should_raise_when_disk_path_missing(self):
        arg = 'onlyhost-or-invalid'
        self.assertRaises(ValueError, self.tm._getDiskPath, arg)
        self.assertRaises(ValueError, self.tm._getDiskHost, arg)
        
    def test_should_return_instance_id_when_in_path(self):
        self.tm.diskDstPath = 'host-42:/the/path/with/inst/42/stuff/foo.0.bar'
        self.tm._getInstanceId()
        self.assertEqual(self.tm.instanceId, 42)

    def test_should_raise_when_missing_instance_id_in_path(self):
        self.tm.diskDstPath = 'host-42:/the/path/with/inst/wrong-id1-42/stuff/foo.0.bar'
        self.assertRaises(ValueError, self.tm._getInstanceId)
        
    def test_should_raise_when_too_many_candidates_in_path_for_instance_id(self):
        self.tm.diskDstPath = 'host-42:/the/path/with/inst/42/43/stuff/foo.0.bar'
        self.assertRaises(ValueError, self.tm._getInstanceId)
        
    def test_should_find_numbers(self):
        elems = ['foo', '42', '3', 'bar', '71']
        self.assertEquals(self.tm._findNumbers(elems), [42, 3, 71])
        
    def test_should_return_mp_image_id(self):
        diskSrc = 'http://marketplace:8383/path/image-id-xy'
        self.assertEquals(self.tm._getImageIdFromURI(diskSrc), 'image-id-xy')
        
    def test_should_return_mp_image_id_despite_trailing_slash(self):
        diskSrc = 'http://marketplace:8383/path/image-id-xy/'
        self.assertEquals(self.tm._getImageIdFromURI(diskSrc), 'image-id-xy')
    
    def test_should_return_mp_endpoint(self):
        self.tm.diskSrc = 'http://marketplace:8383/path/image-id-xy/'
        self.assertEquals(self.tm._getMarketplaceEndpointFromURI(), 'http://marketplace:8383/')
        
    def test_should_raise_on_invalid_qemu_output(self):
        qemuOutput = '''
image: ttylinux-10.0-i486-base-1.0.img
file format: raw
virtual size: 31M
disk size: 31M
                     '''
        self.assertRaises(ValueError, self.tm._getVirtualSizeBytesFromQemu, qemuOutput)
        self.assertRaises(ValueError, self.tm._getVirtualSizeBytesFromQemu, 'invalid')
        
    def test_should_return_img_bytes(self):
        qemuOutput = '''
image: ttylinux-10.0-i486-base-1.0.img
file format: raw
virtual size: 31M (32768000 bytes)
disk size: 31M
                     '''
        self.assertEqual(self.tm._getVirtualSizeBytesFromQemu(qemuOutput), 32768000)
        
    def test_should_return_at_least_1G(self):
        self.assertEqual(self.tm._bytesToGiga(32768000), 1)
        
    def test_should_return_size_in_giga(self):
        self.assertEqual(self.tm._bytesToGiga(327680000000), 305)
    
if __name__ == '__main__':
    main()