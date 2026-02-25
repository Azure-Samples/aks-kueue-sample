// AKS Cluster with system node pool
// Azure CNI Overlay, AzureLinux 3, system-assigned managed identity

@description('Azure region for the AKS cluster')
param location string

@description('Name of the AKS cluster')
param clusterName string

@description('Kubernetes version')
param kubernetesVersion string

@description('VM size for system node pool')
param systemVmSize string

@description('Number of system nodes')
param systemNodeCount int

resource aksCluster 'Microsoft.ContainerService/managedClusters@2025-01-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: clusterName
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: systemNodeCount
        vmSize: systemVmSize
        mode: 'System'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        type: 'VirtualMachineScaleSets'
      }
    ]
  }
}

@description('Name of the AKS cluster')
output aksName string = aksCluster.name

@description('Resource ID of the AKS cluster')
output aksId string = aksCluster.id

@description('Node resource group name')
output aksNodeResourceGroupName string = aksCluster.properties.nodeResourceGroup

@description('Kubelet identity object ID')
output kubeletIdentityObjectId string = aksCluster.properties.identityProfile.kubeletidentity.objectId
