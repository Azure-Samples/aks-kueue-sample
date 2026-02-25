using './main.bicep'

// Sensible defaults for the ASML ML cluster demo
// See RULES.md for quota, cost, and operational guidelines
param clusterName = 'aks-ml-demo'
param location = 'southafricanorth'  // GPU quota is here — see RULES.md §1
param gpuVmSize = 'Standard_ND96isr_H100_v5'
param gpuNodeCount = 1
param migMode = readEnvironmentVariable('migMode', 'none')
param systemVmSize = 'Standard_D4s_v5'
param systemNodeCount = 2
param kubernetesVersion = '1.33'
