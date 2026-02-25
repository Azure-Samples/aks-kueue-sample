// GPU node pool for ND-series H100 instances
// GPU drivers managed by NVIDIA GPU Operator — skip AKS built-in driver
// MIG partitioning set at creation time via gpuInstanceProfile (immutable)

@description('Name of the existing AKS cluster')
param clusterName string

@description('VM size for GPU nodes')
param gpuVmSize string

@description('Number of GPU nodes')
param gpuNodeCount int

@description('MIG GPU instance profile: none, MIG1g, MIG2g, MIG3g, MIG4g, MIG7g')
@allowed(['none', 'MIG1g', 'MIG2g', 'MIG3g', 'MIG4g', 'MIG7g'])
param gpuInstanceProfile string = 'none'

resource aksCluster 'Microsoft.ContainerService/managedClusters@2025-01-01' existing = {
  name: clusterName
}

resource gpuNodePool 'Microsoft.ContainerService/managedClusters/agentPools@2025-01-01' = {
  parent: aksCluster
  name: 'gpu'
  properties: {
    count: gpuNodeCount
    vmSize: gpuVmSize
    mode: 'User'
    osType: 'Linux'
    osSKU: 'Ubuntu'
    type: 'VirtualMachineScaleSets'
    nodeTaints: [
      'nvidia.com/gpu=present:NoSchedule'
    ]
    nodeLabels: {
      'gpu-type': 'nvidia-h100'
    }
    gpuProfile: gpuInstanceProfile == 'none' ? {
      driver: 'None'
    } : null
    gpuInstanceProfile: gpuInstanceProfile != 'none' ? gpuInstanceProfile : null
  }
}

output gpuNodePoolName string = gpuNodePool.name
