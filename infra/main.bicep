targetScope = 'subscription'

// =====================================================================================
// Entry point for `azd up`. Creates the resource group and delegates to resources.bicep.
// Deploys EITHER a long-running Container App (deploymentMode=app, default) OR an
// event-driven Container Apps Job (deploymentMode=jobs) reading the same queue.
// =====================================================================================

@minLength(1)
@maxLength(64)
@description('Name of the azd environment. Used to derive resource names and the resource group.')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Override the resource group name. Defaults to rg-<environmentName>.')
param resourceGroupName string = ''

@allowed([
  'app'
  'jobs'
  'warmjob'
  'flexjob'
])
@description('Workload to deploy: long-running Container App (app, default), event-driven Container Apps Job (jobs), warm event-driven Job (warmjob), or event-driven Job on a Flex workload profile (flexjob).')
param deploymentMode string = 'app'

// ---- Scaler config (typed as strings for safe azd ${VAR=default} substitution) ------
@description('Minimum replica count for the App worker. Customer-confirmed: 2.')
param minReplicas string = '2'

@description('Maximum replica count for the App worker. Customer-confirmed: 15.')
param maxReplicas string = '15'

@description('KEDA queueLength: target messages per replica before scaling out. Customer-confirmed: 1.')
param queueLength string = '1'

@allowed([
  'all'
  'visibleonly'
])
@description('KEDA queueLengthStrategy. "all" counts visible+invisible; "visibleonly" counts visible only.')
param queueLengthStrategy string = 'all'

@description('KEDA polling interval in seconds. Customer-confirmed: 30.')
param pollingInterval string = '30'

@description('KEDA cooldown period in seconds (scale-to-zero only). Customer-confirmed: 300.')
param cooldownPeriod string = '300'

@description('Graceful shutdown window before SIGKILL in seconds. Customer-confirmed: 600.')
param terminationGracePeriodSeconds string = '600'

@description('Max wall-clock seconds a single Job execution may run. 3600 = 60 min.')
param replicaTimeout string = '3600'

@description('Max concurrent Job executions KEDA may start. Mirrors maxReplicas.')
param jobMaxExecutions string = '15'

@description('Warm-Job floor: executions kept always-running (warmjob mode). Mirrors minReplicas. Default 2.')
param warmJobMinExecutions string = '2'

@description('Warm-Job drain safety margin (seconds): stop pulling new work this long before replicaTimeout. Must exceed the worst-case cold-start delta (3 GB pull + scheduling), not the job duration. Default 300.')
param drainSafetyMarginSeconds string = '300'

@description('Warm-Job drain deadline stagger (seconds): deterministic per-execution spread so floor executions do not roll over in lockstep. Default 60.')
param drainStaggerSeconds string = '60'

@description('Workload profile type used by flexjob mode (workloadProfileType on the managed environment). Default Flex.')
param flexWorkloadProfileType string = 'Flex'

@description('Name of the storage queue jobs are read from.')
param queueName string = 'jobs'

@description('Name of the table used for durable job state.')
param stateTableName string = 'jobstate'

@description('Worker CPU cores (e.g. 0.5).')
param workerCpu string = '0.5'

@description('Worker memory (e.g. 1Gi).')
param workerMemory string = '1Gi'

var rgName = empty(resourceGroupName) ? 'rg-${environmentName}' : resourceGroupName
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
  'deployment-mode': deploymentMode
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    deploymentMode: deploymentMode
    minReplicas: int(minReplicas)
    maxReplicas: int(maxReplicas)
    queueLength: int(queueLength)
    queueLengthStrategy: queueLengthStrategy
    pollingInterval: int(pollingInterval)
    cooldownPeriod: int(cooldownPeriod)
    terminationGracePeriodSeconds: int(terminationGracePeriodSeconds)
    replicaTimeout: int(replicaTimeout)
    jobMaxExecutions: int(jobMaxExecutions)
    warmJobMinExecutions: int(warmJobMinExecutions)
    drainSafetyMarginSeconds: int(drainSafetyMarginSeconds)
    drainStaggerSeconds: int(drainStaggerSeconds)
    flexWorkloadProfileType: flexWorkloadProfileType
    queueName: queueName
    stateTableName: stateTableName
    workerCpu: workerCpu
    workerMemory: workerMemory
  }
}

// Outputs consumed by azd (image push) and the helper scripts.
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.registryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.registryName
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output DEPLOYMENT_MODE string = resources.outputs.deploymentMode
output WORKER_RESOURCE_NAME string = resources.outputs.workerResourceName
output STORAGE_ACCOUNT_NAME string = resources.outputs.storageAccountName
output QUEUE_NAME string = queueName
output STATE_TABLE_NAME string = stateTableName
output LOG_ANALYTICS_WORKSPACE_NAME string = resources.outputs.logAnalyticsWorkspaceName
output CONTAINER_APP_ENVIRONMENT_NAME string = resources.outputs.containerAppsEnvironmentName
