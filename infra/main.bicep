// Orchestrator: AKS ML Cluster with GPU node pool
// Helm installs (Kueue, Coder, GPU Operator) and Kueue config are applied
// locally via deploy.sh using the caller's kubeconfig.

targetScope = 'resourceGroup'

// --- Parameters ---

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Name of the AKS cluster')
param clusterName string = 'aks-ml-demo'

@description('GPU node VM size')
param gpuVmSize string = 'Standard_ND96isr_H100_v5'

@description('Number of GPU nodes')
param gpuNodeCount int = 1

@description('MIG mode: none (whole GPUs), MIG1g (7 slices/GPU), MIG2g (3 slices), MIG3g (2 slices), MIG7g (1 full)')
@allowed(['none', 'MIG1g', 'MIG2g', 'MIG3g', 'MIG4g', 'MIG7g'])
param migMode string = 'none'

@description('System node pool VM size')
param systemVmSize string = 'Standard_D4s_v5'

@description('Number of system nodes')
param systemNodeCount int = 2

@description('Kubernetes version')
param kubernetesVersion string = '1.33'

// --- AKS Cluster ---

module aksCluster 'modules/aks-cluster.bicep' = {
  name: 'aks-cluster'
  params: {
    location: location
    clusterName: clusterName
    kubernetesVersion: kubernetesVersion
    systemVmSize: systemVmSize
    systemNodeCount: systemNodeCount
  }
}

// --- GPU Node Pool ---

module gpuNodePool 'modules/gpu-nodepool.bicep' = {
  name: 'gpu-nodepool'
  params: {
    clusterName: aksCluster.outputs.aksName
    gpuVmSize: gpuVmSize
    gpuNodeCount: gpuNodeCount
    gpuInstanceProfile: migMode
  }
}

// --- Outputs ---

output aksClusterName string = aksCluster.outputs.aksName
output aksClusterId string = aksCluster.outputs.aksId
output nodeResourceGroup string = aksCluster.outputs.aksNodeResourceGroupName
output migMode string = migMode
