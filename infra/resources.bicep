// =====================================================================================
// All resources for the ACA queue-worker repro / App-vs-Jobs benchmark.
// Deployed at resource-group scope by main.bicep.
//
// deploymentMode selects ONE of four equivalent workloads that read the same queue with the
// same KEDA azure-queue scaler, so their cold-start behaviour can be compared apples-to-apples:
//   'app'     -> Microsoft.App/containerApps : long-running replicas (the customer's model)
//   'jobs'    -> Microsoft.App/jobs          : event-driven run-to-completion executions (cold each)
//   'warmjob' -> Microsoft.App/jobs          : event-driven Job kept warm via minExecutions with a
//                                              drain-before-deadline worker — App-like warm pickup
//                                              plus the Job run-to-completion guarantee.
//   'flexjob' -> Microsoft.App/jobs          : plain event-driven Job (cold each, like 'jobs') but
//                                              scheduled on a Flex workload profile instead of the
//                                              Consumption pool. Flex is single-tenant and does not
//                                              scale its nodes to zero, so nodes stay warm and the
//                                              ~3 GB image can remain cached on-node — the benchmark
//                                              measures whether that removes the per-execution pull.
//        TRADEOFF: a drain execution does not idle-exit, and KEDA never scales a *running*
//        execution down. So after a burst the running-execution count ratchets toward
//        jobMaxExecutions and only returns to the warmJobMinExecutions floor as each execution
//        hits replicaTimeout and rolls over. Keep replicaTimeout modest for warmjob to bound how
//        long burst executions linger — but it MUST stay comfortably above
//        drainSafetyMarginSeconds + drainStaggerSeconds (else the usable drain window is non-positive
//        and the worker disables deadline draining; see Worker.cs). The benchmark measures warm
//        pickup on the idle floor (small enqueue onto a quiescent pool), separately from burst
//        scale-out.
// Both carry the azd-service-name=worker tag; azd detects the resource type and pushes the same
// image to whichever one is deployed.
// =====================================================================================

@allowed([
  'app'
  'jobs'
  'warmjob'
  'flexjob'
])
@description('Which workload to deploy: long-running Container App (app), event-driven Container Apps Job (jobs), warm event-driven Job (warmjob), or event-driven Job on a Flex workload profile (flexjob).')
param deploymentMode string = 'app'

param location string
param resourceToken string
param tags object

param minReplicas int
param maxReplicas int
param queueLength int
param queueLengthStrategy string
param queueName string
param stateTableName string
param workerCpu string
param workerMemory string

@description('KEDA polling interval (seconds). Customer-confirmed value: 30.')
param pollingInterval int = 30

@description('KEDA cooldown period (seconds, scale-to-zero only). Customer-confirmed value: 300.')
param cooldownPeriod int = 300

@description('Graceful shutdown window before SIGKILL (seconds). Customer-confirmed value: 600.')
param terminationGracePeriodSeconds int = 600

// ---- Jobs-only knobs ----------------------------------------------------------------
@description('Max wall-clock time (seconds) a single Job execution may run. Set above the longest job. 3600 = 60 min.')
param replicaTimeout int = 3600

@description('Retries for a failed Job execution.')
param replicaRetryLimit int = 1

@description('Concurrent message processors per Job execution.')
param parallelism int = 1

@description('Successful replicas required for a Job execution to be considered complete.')
param replicaCompletionCount int = 1

@description('Minimum concurrent Job executions KEDA keeps running.')
param jobMinExecutions int = 0

@description('Warm-Job floor: concurrent Job executions kept always-running (warmjob mode). Mirrors the App minReplicas so warm pickup is comparable. Customer-aligned: 2.')
param warmJobMinExecutions int = 2

@description('Maximum concurrent Job executions KEDA may start.')
param jobMaxExecutions int = 15

@description('Warm-Job (drain) safety margin in seconds: stop pulling new work this long before replicaTimeout so the in-flight job finishes and the execution exits cleanly for rollover. Because the worker anchors its deadline at process start while replicaTimeout starts at execution creation, this must exceed the worst-case cold-start delta (3 GB pull + scheduling, ~47-162 s here), not the job duration.')
param drainSafetyMarginSeconds int = 300

@description('Warm-Job (drain) deterministic per-execution deadline stagger (seconds) so floor executions do not roll over in lockstep. 0 disables.')
param drainStaggerSeconds int = 60

@description('How long a received message stays invisible while a job runs. Keep above max job duration.')
param visibilityTimeoutSeconds int = 3600

@description('How often the worker emits/persists progress.')
param progressIntervalSeconds int = 30

@description('Placeholder image used until azd pushes the real worker image.')
param placeholderImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Workload profile type for flexjob mode. Deployed as a named profile on the managed environment and referenced by the Job. Default Flex.')
param flexWorkloadProfileType string = 'Flex'

var isApp = deploymentMode == 'app'
var isWarmJob = deploymentMode == 'warmjob'
var isFlexJob = deploymentMode == 'flexjob'
// 'jobs', 'warmjob' and 'flexjob' all deploy the Microsoft.App/jobs resource.
var isJob = deploymentMode == 'jobs' || isWarmJob || isFlexJob

// App => loop forever (long-running replica); jobs/flexjob => process one message and exit;
// warmjob => poll forever (warm pickup) but drain & exit before replicaTimeout for safe rollover.
var runMode = isApp ? 'loop' : (isWarmJob ? 'drain' : 'once')

// Warm Job keeps a floor of always-running executions; plain Job (incl. flexjob) scales from zero.
var effectiveJobMinExecutions = isWarmJob ? warmJobMinExecutions : jobMinExecutions

// flexjob schedules the Job on a named Flex workload profile; all other modes use the default
// Consumption pool (no workload profiles on the environment, workloadProfileName unset).
var flexProfileName = 'flex'

// Flex profiles only accept fixed CPU/memory combos (0.25/1Gi, 0.5/2Gi, 1/4Gi, ...). The template
// default 0.5 CPU pairs with 1Gi on Consumption but must be 2Gi on Flex, so snap the default memory
// up for flexjob to keep `azd up` working out of the box. Memory does not affect image-pull timing,
// so the cold-start benchmark stays comparable. Non-flex modes keep the requested memory.
var effectiveWorkerMemory = (isFlexJob && workerMemory == '1Gi') ? '2Gi' : workerMemory

var abbrs = {
  storageAccount: 'st'
  registry: 'acr'
  identity: 'id'
  logAnalytics: 'log'
  containerAppsEnv: 'cae'
  containerApp: 'ca'
  job: 'cj'
}

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// ---- Log Analytics ------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${abbrs.logAnalytics}-${resourceToken}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ---- User-assigned managed identity (ACR pull) --------------------------------------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${abbrs.identity}-${resourceToken}'
  location: location
  tags: tags
}

// ---- Container Registry --------------------------------------------------------------
resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: '${abbrs.registry}${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    // Admin user lets `azd`/CI push reliably; the app pulls via managed identity (AcrPull below).
    adminUserEnabled: true
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, uami.id, acrPullRoleId)
  scope: registry
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}

// ---- Storage (queue + table) --------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${abbrs.storageAccount}${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource jobsQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: queueName
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource stateTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: stateTableName
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

// ---- Container Apps environment -----------------------------------------------------
// flexjob needs a workload-profiles-enabled environment carrying the default Consumption pool
// plus a named Flex profile; all other modes use a plain (Consumption-only) environment.
var flexWorkloadProfiles = [
  {
    name: 'Consumption'
    workloadProfileType: 'Consumption'
  }
  {
    name: flexProfileName
    workloadProfileType: flexWorkloadProfileType
  }
]

resource containerAppsEnv 'Microsoft.App/managedEnvironments@2025-02-02-preview' = {
  name: '${abbrs.containerAppsEnv}-${resourceToken}'
  location: location
  tags: tags
  properties: union({
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }, isFlexJob ? { workloadProfiles: flexWorkloadProfiles } : {})
}

// Shared container env. RunMode flips the same image between long-running and run-once behaviour.
var workerEnv = [
  {
    name: 'STORAGE_CONNECTION_STRING'
    secretRef: 'storage-connection-string'
  }
  {
    name: 'Worker__QueueName'
    value: queueName
  }
  {
    name: 'Worker__StateTableName'
    value: stateTableName
  }
  {
    name: 'Worker__VisibilityTimeoutSeconds'
    value: string(visibilityTimeoutSeconds)
  }
  {
    name: 'Worker__ProgressIntervalSeconds'
    value: string(progressIntervalSeconds)
  }
  {
    name: 'Worker__RunMode'
    value: runMode
  }
  {
    // drain mode reads these to roll over before replicaTimeout; ignored by loop/once.
    name: 'Worker__ReplicaDeadlineSeconds'
    value: string(replicaTimeout)
  }
  {
    name: 'Worker__DrainSafetyMarginSeconds'
    value: string(drainSafetyMarginSeconds)
  }
  {
    name: 'Worker__DrainStaggerSeconds'
    value: string(drainStaggerSeconds)
  }
]

var registriesConfig = [
  {
    server: registry.properties.loginServer
    identity: uami.id
  }
]

var secretsConfig = [
  {
    name: 'storage-connection-string'
    value: storageConnectionString
  }
]

// ---- Option A: long-running Container App (customer model) --------------------------
resource workerApp 'Microsoft.App/containerApps@2025-02-02-preview' = if (isApp) {
  name: '${abbrs.containerApp}-worker-${resourceToken}'
  location: location
  // azd matches this tag to the service named "worker" in azure.yaml and pushes its image here.
  tags: union(tags, {
    'azd-service-name': 'worker'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      // No ingress: this is a background queue worker.
      registries: registriesConfig
      secrets: secretsConfig
    }
    template: {
      terminationGracePeriodSeconds: terminationGracePeriodSeconds
      containers: [
        {
          name: 'worker'
          image: placeholderImage
          resources: {
            cpu: json(workerCpu)
            memory: effectiveWorkerMemory
          }
          env: workerEnv
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        pollingInterval: pollingInterval
        cooldownPeriod: cooldownPeriod
        rules: [
          {
            name: 'queue-scaling'
            custom: {
              type: 'azure-queue'
              metadata: {
                queueName: queueName
                queueLength: string(queueLength)
                queueLengthStrategy: queueLengthStrategy
                accountName: storage.name
              }
              auth: [
                {
                  secretRef: 'storage-connection-string'
                  triggerParameter: 'connection'
                }
              ]
            }
          }
        ]
      }
    }
  }
}

// ---- Option B/C: event-driven Container Apps Job (jobs = cold each; warmjob = warm floor) ----
resource workerJob 'Microsoft.App/jobs@2025-02-02-preview' = if (isJob) {
  name: '${abbrs.job}-worker-${resourceToken}'
  location: location
  tags: union(tags, {
    'azd-service-name': 'worker'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnv.id
    workloadProfileName: isFlexJob ? flexProfileName : null
    configuration: {
      triggerType: 'Event'
      replicaTimeout: replicaTimeout
      replicaRetryLimit: replicaRetryLimit
      registries: registriesConfig
      secrets: secretsConfig
      eventTriggerConfig: {
        parallelism: parallelism
        replicaCompletionCount: replicaCompletionCount
        scale: {
          minExecutions: effectiveJobMinExecutions
          maxExecutions: jobMaxExecutions
          pollingInterval: pollingInterval
          rules: [
            {
              name: 'queue-scaling'
              type: 'azure-queue'
              metadata: {
                queueName: queueName
                queueLength: string(queueLength)
                queueLengthStrategy: queueLengthStrategy
                accountName: storage.name
              }
              auth: [
                {
                  secretRef: 'storage-connection-string'
                  triggerParameter: 'connection'
                }
              ]
            }
          ]
        }
      }
    }
    template: {
      containers: [
        {
          name: 'worker'
          image: placeholderImage
          resources: {
            cpu: json(workerCpu)
            memory: effectiveWorkerMemory
          }
          env: workerEnv
        }
      ]
    }
  }
}

output registryLoginServer string = registry.properties.loginServer
output registryName string = registry.name
output workerResourceName string = isApp ? workerApp.name : workerJob.name
output deploymentMode string = deploymentMode
output storageAccountName string = storage.name
output logAnalyticsWorkspaceName string = logAnalytics.name
output containerAppsEnvironmentName string = containerAppsEnv.name
