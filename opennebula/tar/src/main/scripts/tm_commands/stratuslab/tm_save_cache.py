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
from stratuslab.ConfigHolder import ConfigHolder
from stratuslab.Configurator import Configurator
from stratuslab.Util import defaultConfigFile, sshCmdWithOutputQuiet,\
    SSH_EXIT_STATUS_ERROR
from os.path import basename, dirname
from stratuslab.ManifestInfo import ManifestIdentifier, ManifestInfo
from stratuslab.installator.PersistentDisk import PersistentDisk
from signal import signal, SIGINT
from os import removedirs, remove, renames
from os.path import isfile, isdir
from tempfile import mkstemp, mkdtemp
from random import choice
from string import ascii_uppercase, digits
from stratuslab.CertGenerator import CertGenerator
from stratuslab.CloudConnectorFactory import CloudConnectorFactory
from stratuslab.Authn import LocalhostCredentialsConnector
from stratuslab.Creator import Creator
from shutil import move
from stratuslab.marketplace.Uploader import Uploader
from email.mime.text import MIMEText
from smtplib import SMTP

class TMSaveCache(object):
    ''' Save a running VM image in PDisk
    '''

    # Position of the provided args
    _ARG_SRC_POS = 1
    _ARG_DST_POS = 2
    
    # Provided arguments information location (e. g. HOST:PATH) 
    _HOST_PART = 0
    _PATH_PART = 1

    _PDISK_PORT = 8445
    _P12_VALIDITY = 2
    
    _CHECKSUM = 'sha1'
    _CHECKSUM_CMD = '%ssum' % _CHECKSUM
    
    def __init__(self, args, **kwargs):
        self.args = args
        
        self.diskSrcPath = None
        self.diskSrcHost = None
        self.vmDir = None
        self.registerFile = None
        self.diskName = None
        self.pdiskHostPort = None
        self.snapshotId = None
        self.createdPDiskId = None
        self.p12cert = None
        self.p12pswd = None
        self.manifestTempDir = None
        self.manifestPath = None
        self.manifestNotSignedPath = None
        self.pdiskPath = None
        self.pdiskPathNew = None
        self.originImageId = None
        self.originMarketPlace = None
        self.instanceId = None
        self.imageSha1 = None
        self.createImageInfo = None
        
        self.configHolder = ConfigHolder({'verboseLevel': 0,
                                          'configFile': kwargs.get('config', defaultConfigFile)})
        self.config = Configurator(self.configHolder)
        self.pdiskEndpoint = self.config.getValue('persistent_disk_ip')    
        self.pdiskLVMDevice = self.config.getValue('persistent_disk_lvm_device')
        self.pdiskLVMName = basename(self.pdiskLVMDevice)
        
        credentials = LocalhostCredentialsConnector(self)
        self.cloud = CloudConnectorFactory.getCloud(credentials)
    
    def run(self):
        self._checkArgs()
        self._parseArgs()
        self._getInstanceId()
        self._getVmDir()
        self._getPDiskInfo()
        self._detachPDisk()
        self._getSnapshotId()
        self._getOriginImageInfo()
        self._rebaseSnapshot()
        self._generateManifest()
        self._uploadManifest()
        self._sendEmailToUser()
    
    def _checkArgs(self):
        if len(self.args) != 3:
            raise ValueError('Invalid number of arguments')
    
    def _parseArgs(self):
        src = self.args[self._ARG_SRC_POS]
        self.diskSrcPath = self._getDiskPath(src)
        self.diskSrcHost = self._getDiskHost(src)
    
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
        pathElems = self.diskSrcPath.split('/')
        instanceId = self._findNumbers(pathElems)
        errorMsg = '%s instance ID in path. ' + 'Path is "%s"' % self.diskSrcPath
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
    
    def _getVmDir(self):
        self.vmDir = dirname(dirname(self.diskSrcPath))
        
    def _getPDiskInfo(self):
        self._sourcePDiskHostConfig()
        pdiskInfos = self._getPDiskServerInfo()
        self.pdiskPath = self._removeCarriageReturn(pdiskInfos)
        self.diskName = self._getDiskNameFormURI(self.pdiskPath)
        self.pdiskHostPort = self._getPDiskHostPortFromURI(self.pdiskPath) 
    
    def _sourcePDiskHostConfig(self):
        confFile = '/etc/stratuslab/pdisk-host.cfg'
        self._sshDst(['source', confFile], 
                     'Unable to source pdisk host config at "%"' % confFile)

    def _getPDiskServerInfo(self):
        return self._sshDst(['head', '-1', '%s/$REGISTER_FILENAME' % self.vmDir], 
                            'Unable to get pdisk server info')
    
    def _getDiskNameFormURI(self, uri):
        return uri.split(':')[-1]
    
    def _getPDiskHostPortFromURI(self, uri):
        self._assertLength(uri, 4)
        return ':'.join(uri.split(':')[1:3])
    
    def _detachPDisk(self):
        self._sshDst(['/usr/sbin/detach-persistent-disk.sh', self.vmDir], 
                     'Unable to detach pdisk at "%s"' % self.vmDir)
    
    def _getSnapshotId(self):
        self.imageSha1 = self._getSnaptshotSha1()
        self.snapshotId = ManifestIdentifier().sha1ToIdentifier(self.imageSha1)
        
    def _getSnaptshotSha1(self):
        snapshotPath = self._getSnapshotPath()
        checksumOutput = self._ssh(self.pdiskEndpoint, [self._CHECKSUM_CMD, snapshotPath],
                                   'Unable to compute checksum of "%s"' % snapshotPath)
        checksumElems = checksumOutput.split(' ')
        self._assertLength(checksumElems, 2)
        return checksumElems[1]
    
    def _getSnapshotPath(self):
        return '%s/%s' % (self.pdiskLVMDevice, self.diskName)
       
    def _getOriginImageInfo(self):
        vmSource = self.cloud.getVmSource(self.instanceId)
        self.originImageId = vmSource.split('/')[-1]
        self.originMarketPlace = '/'.join(vmSource.split('/')[:-2])
        
    def _rebaseSnapshot(self):
        pdisk = PersistentDisk(self.configHolder)
        self.createdPDiskId = pdisk.rebaseVolume(self.snapshotId)
        pdisk.updateVolume({'tag': self.snapshotId}, self.createdPDiskId)
        
    def _generateManifest(self):
        self._startCriticalSection(self._removeTempFilesAndDirs)
        try:
            self._generateP12Cert()
            self._createManifest()
        except:
            self._removeTempFilesAndDirs()
        self._endCriticalSection()

    def _generateP12Cert(self):
        self.p12cert = mkstemp('.p12', 'cert-')[1]
        self.p12pswd = self.randomString()
        options = { 'commonName': 'Jane Tester',
                    'outputFile': self.p12cert,
                    'certPassword': self.p12pswd,
                    'certValidity': self._P12_VALIDITY,
                    'subjectEmail': 'jane.tester@example.org'}
        CertGenerator(options).generateP12()

    def _createManifestTempDir(self):
        mkdtemp(prefix='manifest-')
        
    def _getManifestsPath(self):
        self._createManifestTempDir()
        self.manifestPath = '%s/manifest.xml' % self.manifestTempDir 
        self.manifestNotSignedPath = '%s/manifest-not-signed.xml' % self.manifestTempDir
         
    def _createManifest(self):
        self._getManifestsPath()
        self.createImageInfo = self._getCreateImageInfo()
        self.pdiskPathNew = self._buildPDiskPath(self.createdPDiskId)
        self._buildCreator()
        self._renameManifest()
        
    def _getCreateImageInfo(self):
        return self.cloud.getCreateImageInfo(self.instanceId)
        
    def _buildCreator(self):
        creator = Creator(self.originImageId, ConfigHolder())
        creator._retrieveManifest()
        creator.checksums['sha1']['sum'] = self.imageSha1
        creator.author = self.createImageInfo['creatorName']
        creator.newImageGroupVersion = self.createImageInfo['newImageVersion']
        creator.comment = self.createImageInfo['newImageComment']
        creator.manifestObject = creator._updateManifest()
        creator.manifestObject.locations = [self.pdiskPathNew, ]
        creator.manifest = creator.manifestObject.tostring()
        creator._saveManifest()
        move(creator.manifestLocalFileName, self.manifestPath)
        creator.manifestLocalFileName = self.manifestPath
        creator._signManifest()
        
    def _renameManifest(self):
        renames(self.manifestPath, self.manifestNotSignedPath)
        
    def _uploadManifest(self):
        uploader = Uploader(self.configHolder)
        uploader.marketplaceEndpoint = self.originMarketPlace
        uploader.upload(self.manifestNotSignedPath)
    
    def _sendEmailToUser(self):
        if not self.createImageInfo['creatorEmail']:
            return
        msg = MIMEText(self._emailText())
        msg['Subject'] = 'New image created %smtp' % self.snapshotId
        msg['From'] = 'noreply@stratuslab.eu'
        msg['To'] = self.createImageInfo['creatorEmail']
        msg.attach(self.manifestNotSignedPath)
        smtp = SMTP('localhost')
        smtp.sendmail('noreply@stratuslab.eu', self.createImageInfo['creatorEmail'], 
                   msg.as_string())
        smtp.quit()
        # TODO: Call msg-publisher if msg_type defined in VM template
    
    def _buildPDiskPath(self, imageId):
        return ':'.join(self.pdiskPath.split(':')[:-1])
         
    def _assertLength(self, elem, size):
        if len(elem) != size:
            raise ValueError('List should have %s element(s), got %s' % (size, len(elem)))
    
    def randomString(self, size=6):
        chars = ascii_uppercase + digits
        return ''.join(choice(chars) for _ in range(size))
    
    def _removeCarriageReturn(self, string):
        return string.replace('\r', '')
    
    def _sshDst(self, cmd, errorMsg, dontRaiseOnError=False):
        return self._ssh(self.diskSrcHost, cmd, errorMsg, dontRaiseOnError)
    
    def _ssh(self, host, cmd, errorMsg, dontRaiseOnError=False):
        retcode = sshCmdWithOutputQuiet(cmd, host, pseudoTTY=True)
        if not dontRaiseOnError and retcode == SSH_EXIT_STATUS_ERROR:
            raise Exception(errorMsg)
        return retcode 
    
    def _removeTempFilesAndDirs(self):
        if isdir(self.manifestTempDir):
            removedirs(self.manifestTempDir)
        if isfile(self.p12cert):
            remove(self.p12cert)
    
    def _startCriticalSection(self, callFunc):
        self.defaultSignalHandler = signal(SIGINT, callFunc)
        
    def _endCriticalSection(self):
        signal(SIGINT, self.defaultSignalHandler)
    
    def _emailText(self):
        return """
Image creation was successful.
New image was stored in local PDISK service
https://%(pdiskHostPort)s/cert/disks/%(pdiskId)s
https://%(pdiskHostPort)s/pswd/disks/%(pdiskId)s
Image manifest with ID %(snapshotId)s was signed with dummy certificate and uploaded to %(marketplace)s.
Alternatively, you can sign attached manifest and upload to Marketplace with:
stratus-sign-metadata <manifest file>
stratus-upload-metadata <manifest file>

NB! The validity of the manifest is %(imageValidity)s hours. Please change it!

The validity of the signing certificate is %(p12Validity)s days.

Cheers.
        """ % {'pdiskHostPort': self.pdiskHostPort,
               'pdiskId': self.createdPDiskId,
               'snapshotId': self.snapshotId,
               'marketplace': self.originMarketPlace,
               'p12Validity': self._P12_VALIDITY,
               'imageValidity': self._P12_VALIDITY * 24 }
    