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
import sys
from os.path import basename, isdir
from stratuslab.ConfigHolder import ConfigHolder
from stratuslab.Configurator import Configurator
from os import makedirs
from stratuslab.Util import SSH_EXIT_STATUS_ERROR, sshCmdWithOutputQuiet,\
    defaultConfigFile
from stratuslab.PersistentDisk import PersistentDisk
from urlparse import urlparse
from stratuslab.marketplace.Policy import Policy
from signal import signal, SIGINT
from stratuslab.Authn import LocalhostCredentialsConnector
from stratuslab.CloudConnectorFactory import CloudConnectorFactory
from stratuslab.marketplace.ManifestDownloader import ManifestDownloader
from time import time

class TMCloneCache(object):
    ''' Clone or retrieve from cache disk image
    '''

    # Position of the provided args
    _ARG_SRC_POS = 1
    _ARG_DST_POS = 2
    
    # Provided arguments information location (e. g. HOST:PATH) 
    _HOST_PART = 0
    _PATH_PART = 1

    _PDISK_PORT = 8445
    
    _UNCOMPRESS_TOOL = {'gz': '/bin/gunzip',
                       'bz2': '/bin/bunzip2'}
    
    _CHECKSUM = 'sha1'
    _CHECKSUM_CMD = '%ssum' % _CHECKSUM

    def __init__(self, args, **kwargs):
        self.args = args
        
        self.diskSrc = None
        self.diskDstPath = None
        self.diskDstHost = None
        self.instanceId = None
        self.marketplaceEndpoint = None
        self.marketplaceImageID = None
        self.pdiskImageId = None
        self.pdiskSnapshotId = None
        self.downloadedLocalImageLocation = None
        self.downloadedLocalImageSize = 0
        
        self.configHolder = ConfigHolder({'verboseLevel': 0,
                                     'configFile': kwargs.get('config', defaultConfigFile)})
        self.config = Configurator(self.configHolder)
        self.pdiskEndpoint = self.config.getValue('persistent_disk_ip')    
        self.pdiskLVMDevice = self.config.getValue('persistent_disk_lvm_device')
        
        self.pdisk = PersistentDisk(self.configHolder)
        self.manifestDownloader = ManifestDownloader(self.configHolder)
        
        self.defaultSignalHandler = None
    
    def run(self):
        self._checkArgs()
        self._parseArgs()
        self._getInstanceId()
        self._retrieveDisk()
    
    def _checkArgs(self):
        if len(self.args) != 3:
            raise ValueError('Invalid number of arguments')
    
    def _parseArgs(self):
        dst = self.args[self._ARG_DST_POS]
        self.diskDstHost = self._getDiskHost(dst)
        self.diskDstPath = self._getDiskPath(dst)
        self.diskSrc = self.args[self._ARG_SRC_POS]
    
    def _getDiskPath(self, arg):
        return self._getLocationPart(arg, self._PATH_PART)
        
    def _getDiskHost(self, arg):
        return self._getLocationPart(arg, self._HOST_PART)
        
    def _getLocationPart(self, arg, part):
        path = arg.split(':', 1)
        if len(path) != 2:
            raise ValueError('Missing location part have "%s" should be [PART_O]:[PART_1]' % arg)
        return path[part]

    def _getInstanceId(self):
        pathElems = self.diskDstPath.split('/')
        instanceId = self._findNumbers(pathElems)
        errorMsg = '%s instance ID in path. ' + 'Path is "%s"' % self.diskDstPath
        if len(instanceId) != 1:
            raise ValueError(errorMsg % ((len(instanceId) == 0) and 'Unable to find' 
                                         or 'Too many candidates'))
        self.instanceId = instanceId.pop()

    def _findNumbers(self, elems):
        findedNb = []
        for nb in elems:
            try:
                findedNb.append(int(nb))
            except Exception:
                pass
        return findedNb
    
    def _retrieveDisk(self):
        if self.diskSrc.startswith('pdisk:'):
            self._startFromPersisted()
        else:
            self._startFromCowSnapshot()
    
    def _startFromPersisted(self):
        diskId = self._getLocationPart(self.diskSrc, 1)
        
        if (self._isCowDisk(diskId) or self._isReadOnlyDisk(diskId)):
            raise Exception('Failed booting from "%s". Check that you are the' + 
                            ' owner of the disk, the disk is not readonly and' +
                            ' not a snapshot.' % self.diskSrc)
        
        self._createDstPath()
        self._clonePDisk(self.diskSrc)
            
    def _createDstPath(self):
        self._sshDst(['mkdir', '-p', self.diskDstPath],
                     'Unable to create directory %s' % self.diskDstPath)
    
    def _clonePDisk(self, diskSrc):
        self._sshDst(['/usr/sbin/attach-persistent-disk.sh', diskSrc, self.diskDstPath],
                     'Unable to clone persistent disk at %s' % self.diskDstPath)
        
    def _isCowDisk(self, diskId):
        notCowDisks = self.pdisk.search('iscow', 'false')
        return diskId in notCowDisks
    
    def _isReadOnlyDisk(self, diskId):
        notReadOnlyDisks = self.pdisk.search('isreadonly', 'false')
        return diskId in notReadOnlyDisks
    
    def _startFromCowSnapshot(self):
        self._setMarketplaceInfos()
        if self._cacheMiss():
            self._retrieveAndCachePDiskImage()
        self._startCriticalSection(self._deletePDiskSnapshot)
        try:
            self._createPDiskSnapshot()
            self._setSnapshotOwner()
            self._createDstPath()
            self._clonePDisk(self._getPDiskSnapshotURL())
        except:
            self._deletePDiskSnapshot()
        self._endCriticalSection()
        
    def _setMarketplaceInfos(self):
        if self.diskSrc.startswith('http://'):
            self.marketplaceEndpoint = self._getMarketplaceEndpointFromURI()
            self.marketplaceImageID = self._getImageIdFromURI(self.diskSrc)
        else: # Local marketplace
            self.marketplaceEndpoint = self.config.getValue('marketplace_endpoint')
            # SunStone adds '<hostname>:' to the image ID
            self.marketplaceImageID = self._getLocationPart(self.diskSrc, 1)
    
    def _getMarketplaceEndpointFromURI(self):
        uri = urlparse(self.diskSrc)
        return '%s://%s/' % (uri.scheme, uri.netloc)
    
    def _getImageIdFromURI(self, uri):
        fragments = uri.split('/')
        # POP two times if trailing slash
        return fragments.pop() or fragments.pop()
    
    def _getFullyQualifiedMarketplaceImage(self):
        self.configHolder.set('marketplaceEndpoint', self.marketplaceEndpoint)
        policy = Policy(self.configHolder)
        policyCheckResult = policy.check(self.marketplaceImageID)
        return self._buildFullyQualifiedMarketplaceImage(policyCheckResult, 0)
    
    def _buildFullyQualifiedMarketplaceImage(self, policyCheckResult, imagePos):
        selectedImage = policyCheckResult[imagePos]
        uri = '%s/metadata/%s/%s/%s' % (self.marketplaceEndpoint, 
                                        selectedImage.identifier, 
                                        selectedImage.endorser, 
                                        selectedImage.created)
        return uri
    
    def _getPDiskImageIdsFromMarketplaceImageId(self):
        self.pdisk.search('tag', self.marketplaceImageID)
        
    def _cacheMiss(self):
        foundIds = self._getPDiskImageIdsFromMarketplaceImageId()
        if len(foundIds) > 0:
            self.pdiskImageId = foundIds[0]
            return False
        return True
    
    def _retrieveAndCachePDiskImage(self):
        #marketplaceImageURI = self._getFullyQualifiedMarketplaceImage()
        self.manifestDownloader.downloadManifestByImageId(self.marketplaceImageID)
        self._startCriticalSection(self._deletePDiskSnapshot)
        try:
            self._downloadImage()
            self._uncompressDownloadedImage()
            self._checkDownloadedImageChecksum()
            self._getDowloadedImageSize()
            self._createPDiskFromDowloadedImage()
        except:
            self._deletePDiskSnapshot()
        self._endCriticalSection()
        self._deleteDownloadedImage()
    
    def _downloadImage(self):
        imageLocationOnServer = self.manifestDownloader.getImageLocations()
        imageName = self._getImageIdFromURI(imageLocationOnServer)
        pdiskTmpStore = self._getPDiskTempStore()
        self.downloadedLocalImageLocation = '%s/%s.%s' % (pdiskTmpStore,
                                                          int(time),
                                                          imageName)
        self._sshDst(['curl', '-o', self.downloadedLocalImageLocation, imageLocationOnServer], 
                     'Unable to download "%"' % imageLocationOnServer)
    
    def _uncompressDownloadedImage(self):
        compression = self._getImageCompressionType()
        if not compression:
            return
        uncompressTool = self._UNCOMPRESS_TOOL[compression]
        self._sshDst([uncompressTool, self.downloadedLocalImageLocation],
                     'Unable to uncompress image')
        self.downloadedLocalImageLocation = self._removeExtension(self.downloadedLocalImageLocation)
        
    def _getImageCompressionType(self):
        compression = self.manifestDownloader.getImageElementValue('compression')
        return compression
        
    def _removeExtension(self, filename):
        return '.'.join(filename.split('.')[:-1])
    
    def _getDowloadedImageSize(self):
        qemuImgInfo =self._sshDst(['qemu-img', 'info', self.downloadedLocalImageLocation], 
                                  'Unable to get qemu image info')
        self.downloadedLocalImageSize = self._bytesToGiga(self._getVirtualSizeBytesFromQemu(qemuImgInfo))
        
    def _checkDownloadedImageChecksum(self):
        manifestChecksum = self.manifestDownloader.getImageElementValue(self._CHECKSUM)
        computedChecksum = self._sshDst([self._CHECKSUM_CMD, self.downloadedLocalImageLocation], 'Unable to get image checksum')
        computedChecksum = computedChecksum.split(' ')[0]
        if manifestChecksum is not computedChecksum:
            raise ValueError('Invalid image checksum')
        
    def _createPDiskFromDowloadedImage(self):
        self.pdiskImageId = self.pdisk.createVolume(self.downloadedLocalImageSize, '', False)
        self._setPDiskTag(self.pdiskImageId, self.pdiskImageId)
        self._setNewPDiskReadOnly()
        self._copyDownloadedImageToPartition()
    
    def _setNewPDiskReadOnly(self):
        self.pdisk.updateVolume({'readonly': 'true'}, self.pdiskImageId)
        
    def _copyDownloadedImageToPartition(self):
        imageFormat = self.manifestDownloader.getImageElementValue('format')
        copyCmd = []
        copyDst = '%s/%s' % (self.pdiskLVMDevice, self.pdiskImageId)
        if imageFormat.startswith('qcow'):
            copyCmd = ['cp', '-f', self.downloadedLocalImageLocation, copyDst] 
        else:
            copyCmd = ['dd', 'if=%s' % self.downloadedLocalImageLocation, 'of=%s' % copyDst, 'bs=2048']
        self._sshDst(copyCmd, 'Unable to copy image')
        
    def _deleteDownloadedImage(self):
        self._sshDst(['rm', '-f', self.downloadedLocalImageLocation], 
                     'Unable to remove temporary image', True)
        
    def _getPDiskTempStore(self):
        store = self.config.getValue('persistent_disk_temp_store') or '/tmp'
        if not isdir(store):
            makedirs(store)
        return store
    
    def _createPDiskSnapshot(self):
        snapshotTag = 'snapshot:%s' % self.pdiskImageId
        self.pdiskSnapshotId = self.pdisk.createCowVolume(self.pdiskImageId, None)
        self._setPDiskTag(snapshotTag, self.pdiskSnapshotId)
    
    def _setSnapshotOwner(self):
        owner = self._getInstanceOwner()
        self.pdisk.updateVolume({'owner': owner}, self.pdiskSnapshotId)
    
    def _setPDiskTag(self, tag, pdiskId):
        self.pdisk.updateVolume({'tag': tag}, pdiskId)
    
    def _getInstanceOwner(self):
        credentials = LocalhostCredentialsConnector(self)
        cloud = CloudConnectorFactory.getCloud(credentials)
        return cloud.getVmOwner(self.instanceId)
    
    def _getPDiskSnapshotURL(self):
        return 'pdisk:%s:%s:%s' % (self.pdiskEndpoint, 
                                   self._PDISK_PORT,
                                   self.pdiskSnapshotId)
    
    def _getVirtualSizeBytesFromQemu(self, qemuOutput):
        for line in qemuOutput.split('\n'):
            if line.lstrip().startswith('virtual'):
                bytesAndOtherThings = line.split('(')
                self._assertTwoElements(bytesAndOtherThings)
                bytesAndUnit = bytesAndOtherThings[1].split(' ')
                self._assertTwoElements(bytesAndUnit)
                return int(bytesAndUnit[0])
        raise ValueError('Unable to find image bytes size')
                
    def _assertTwoElements(self, theList):
        if len(theList) != 2:
            raise ValueError('List should have two elements, have "%s"' % theList)
    
    def _bytesToGiga(self, bytesAmout):
        # Return at least 1GB
        return bytesAmout / 1024**3 or 1
    
    def _sshDst(self, cmd, errorMsg, dontRaiseOnError=False):
        retcode = sshCmdWithOutputQuiet(cmd, self.diskDstHost, pseudoTTY=True)
        if not dontRaiseOnError and retcode == SSH_EXIT_STATUS_ERROR:
            raise Exception(errorMsg)
        return retcode
        
    def _startCriticalSection(self, callFunc):
        self.defaultSignalHandler = signal(SIGINT, callFunc)
        
    def _endCriticalSection(self):
        signal(SIGINT, self.defaultSignalHandler)
        
    def _deletePDiskSnapshot(self):
        if self.pdiskSnapshotId is None:
            return
        self.pdisk._setPDiskUserCredentials()
        self.pdisk.deleteVolume(self.pdiskSnapshotId)
        
if __name__ == '__main__':
    try:
        tm = TMCloneCache(sys.argv)
        tm.run()
    except Exception, e:
        print '[%s ERROR] %s' % (basename(__file__), e)
        sys.exit(1)
        