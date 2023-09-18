targetScope = 'subscription'

// ========== //
// Parameters //
// ========== //

@sys.description('AVD workload subscription ID, multiple subscriptions scenario.')
param workloadSubsId string

@sys.description('Resource Group Name for Azure Files.')
param storageObjectsRgName string

@sys.description('Required, The service providing domain services for Azure Virtual Desktop.')
param identityServiceProvider string

@sys.description('Resource Group Name for management VM.')
param serviceObjectsRgName string

@sys.description('Optional, Identity name array to grant RBAC role to access AVD application group and NTFS permissions. (Default: "")')
param securityPrincipalName string

@sys.description('Storage account name.')
param storageAccountName string

@sys.description('Storage account file share name.')
param fileShareName string

@sys.description('Private endpoint subnet ID.')
param privateEndpointSubnetId string

@sys.description('Location where to deploy compute services.')
param sessionHostLocation string

@sys.description('File share SMB multichannel.')
param fileShareMultichannel bool

@sys.description('AD domain name.')
param identityDomainName string

@sys.description('AD domain GUID.')
param identityDomainGuid string

@sys.description('Keyvault name to get credentials from.')
param wrklKvName string

@sys.description('AVD session host domain join credentials.')
param domainJoinUserName string

@sys.description('Azure Files storage account SKU.')
param storageSku string

@sys.description('*Azure File share quota')
param fileShareQuotaSize int

@sys.description('Use Azure private DNS zones for private endpoints.')
param vnetPrivateDnsZoneFilesId string

@sys.description('Tags to be applied to resources')
param tags object

@sys.description('Name for management virtual machine. for tools and to join Azure Files to domain.')
param managementVmName string

@sys.description('Optional. AVD Accelerator will deploy with private endpoints by default.')
param deployPrivateEndpoint bool

@sys.description('Log analytics workspace for diagnostic logs.')
param alaWorkspaceResourceId string

@sys.description('Diagnostic logs retention.')
param diagnosticLogsRetentionInDays int

@sys.description('Do not modify, used to set unique value for resource deployment.')
param time string = utcNow()

@sys.description('Sets purpose of the storage account.')
param storagePurpose string

@sys.description('ActiveDirectorySolution. ')
param ActiveDirectorySolution string = 'ActiveDirectoryDomainServices'

@sys.description('Sets location of DSC Agent.')
param dscAgentPackageLocation string

@sys.description('Custom OU path for storage.')
param storageCustomOuPath string

@sys.description('OU Storage Path')
param ouStgPath string

@sys.description('If OU for Azure Storage needs to be created - set to true and ensure the domain join credentials have priviledge to create OU and create computer objects or join to domain.')
param createOuForStorageString string

@sys.description('Managed Identity Client ID')
param managedIdentityClientId string

@sys.description('Kerberos Encryption. Default is AES256.')
param KerberosEncryption string 

@sys.description('Location of script. Default is located in workload/scripts')
param _artifactsLocation string = 'https://github.com/Azure/avdaccelerator/tree/ntfs-setup/workload/scripts/'

@description('SAS Token to access script.')
param _artifactsLocationSasToken string = ''

@allowed([
    'AzureStorageAccount'
    'AzureNetappFiles'
])
@sys.description ('Storage Solution.')
param storageSolution string 

//borrar
param storageCount int = 1

param storageIndex int = 1
//

@sys.description('Netbios name, will be used to set NTFS file share permissions.')
param netBios string

// =========== //
// Variable declaration //
// =========== //

var varAzureCloudName = environment().name
var varStoragePurposeLower = toLower(storagePurpose)
var varAvdFileShareLogsDiagnostic = [
    'allLogs'
]
var varAvdFileShareMetricsDiagnostic = [
    'Transaction'
]

var varWrklStoragePrivateEndpointName = 'pe-${storageAccountName}-file'
var vardirectoryServiceOptions = (identityServiceProvider == 'AADDS') ? 'AADDS': (identityServiceProvider == 'AAD') ? 'AADKERB': 'None'
//var varStorageToDomainScriptArgs = '-DscPath ${dscAgentPackageLocation} -StorageAccountName ${storageAccountName} -StorageAccountRG ${storageObjectsRgName} -StoragePurpose ${storagePurpose} -DomainName ${identityDomainName} -IdentityServiceProvider ${identityServiceProvider} -AzureCloudEnvironment ${varAzureCloudName} -SubscriptionId ${workloadSubsId} -DomainAdminUserName ${domainJoinUserName} -CustomOuPath ${storageCustomOuPath} -OUName ${ouStgPath} -CreateNewOU ${createOuForStorageString} -ShareName ${fileShareName} -ClientId ${managedIdentityClientId}'
// =========== //
// Deployments //
// =========== //

// Call on the KV.
resource avdWrklKeyVaultget 'Microsoft.KeyVault/vaults@2021-06-01-preview' existing = {
    name: wrklKvName
    scope: resourceGroup('${workloadSubsId}', '${serviceObjectsRgName}')
}

// Provision the storage account and Azure Files.
module storageAndFile '../../../../carml/1.3.0/Microsoft.Storage/storageAccounts/deploy.bicep' = {
    scope: resourceGroup('${workloadSubsId}', '${storageObjectsRgName}')
    name: 'Storage-${storagePurpose}-${time}'
    params: {
        name: storageAccountName
        location: sessionHostLocation
        skuName: storageSku
        allowBlobPublicAccess: false
        publicNetworkAccess: deployPrivateEndpoint ? 'Disabled' : 'Enabled'
        kind: ((storageSku =~ 'Premium_LRS') || (storageSku =~ 'Premium_ZRS')) ? 'FileStorage' : 'StorageV2'
        azureFilesIdentityBasedAuthentication: {
            directoryServiceOptions: vardirectoryServiceOptions
            activeDirectoryProperties: (identityServiceProvider == 'AAD') ? {
                domainGuid: identityDomainGuid
                domainName: identityDomainName
            }: {}
        }
        accessTier: 'Hot'
        networkAcls: deployPrivateEndpoint ? {
            bypass: 'AzureServices'
            defaultAction: 'Deny'
            virtualNetworkRules: []
            ipRules: []
        } : {}
        fileServices: {
            shares: [
                {
                    name: fileShareName
                    shareQuota: fileShareQuotaSize * 100 //Portal UI steps scale
                }
            ]
            protocolSettings: fileShareMultichannel ? {
                smb: {
                    multichannel: {
                        enabled: fileShareMultichannel
                    }
                }
            } : {}
            diagnosticWorkspaceId: alaWorkspaceResourceId
            diagnosticLogCategoriesToEnable: varAvdFileShareLogsDiagnostic
            diagnosticMetricsToEnable: varAvdFileShareMetricsDiagnostic
        }
        privateEndpoints: deployPrivateEndpoint ? [
            {
                name: varWrklStoragePrivateEndpointName
                subnetResourceId: privateEndpointSubnetId
                customNetworkInterfaceName: 'nic-01-${varWrklStoragePrivateEndpointName}'
                service: 'file'
                privateDnsZoneGroup: {
                    privateDNSResourceIds: [
                        vnetPrivateDnsZoneFilesId
                    ]                    
                }
            }
        ] : []
        tags: tags
        diagnosticWorkspaceId: alaWorkspaceResourceId
        diagnosticLogsRetentionInDays: diagnosticLogsRetentionInDays
    }
}

// Call on the VM.
//resource managementVMget 'Microsoft.Compute/virtualMachines@2022-11-01' existing = {
//    name: managementVmName
//    scope: resourceGroup('${workloadSubsId}', '${serviceObjectsRgName}')
//}

module ntfsPermissions '.bicep/ntfsPermissions.bicep' = if (contains(identityServiceProvider, 'ADDS')) {
    name: 'FslogixNtfsPermissions_${time}'
    scope: resourceGroup(workloadSubsId, serviceObjectsRgName)
    params: {
      _artifactsLocation: _artifactsLocation
      _artifactsLocationSasToken: _artifactsLocationSasToken
      CommandToExecute: 'powershell -ExecutionPolicy Unrestricted -File Set-NtfsPermissions.ps1 -ClientId "${managedIdentityClientId}" -DomainJoinUserPrincipalName "${domainJoinUserName}" -ActiveDirectorySolution "${ActiveDirectorySolution}" -Environment "${environment().name}"  -KerberosEncryptionType "${KerberosEncryption}" -StorageAccountFullName "${storageAccountName}" -FileShareName "${fileShareName}" -Netbios "${netBios}" -OuPath "${ouStgPath}" -SecurityPrincipalName "${securityPrincipalName}" -StorageAccountResourceGroupName "${storageObjectsRgName}" -StorageCount ${storageCount} -StorageIndex ${storageIndex} -StorageSolution "${storageSolution}" -StorageSuffix "${environment().suffixes.storage}" -SubscriptionId "${subscription().subscriptionId}" -TenantId "${subscription().tenantId}"'
      Location: sessionHostLocation
      domainJoinUserPassword: avdWrklKeyVaultget.getSecret('domainJoinUserPassword')
      ManagementVmName: managementVmName
      Timestamp: time
    }
    //...
  }

// =========== //
//   Outputs   //
// =========== //
