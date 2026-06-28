# Setup

Prerequisites and one-time setup to deploy this reproduction in your own Azure subscription.

## Prerequisites

| Tool | Version | Purpose |
| --- | --- | --- |
| [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) | 1.9+ | One-command provision + deploy |
| [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) | 2.55+ | Connection strings, log queries |
| [Docker](https://docs.docker.com/get-docker/) | 24+ | Builds the worker image |
| [.NET SDK](https://dotnet.microsoft.com/download) | 8.0+ | Build/run worker and enqueuer locally |
| PowerShell | 7+ | Helper scripts in `/scripts` |

You also need an Azure subscription with permission to create resource groups, storage,
Container Registry, and Container Apps, and to assign roles (the deployment grants the worker's
managed identity `AcrPull`).

## Azure login

```pwsh
az login
azd auth login
```

If you have multiple subscriptions, select the target one:

```pwsh
az account set --subscription "<subscription-id>"
```

## Deploy everything

```pwsh
azd up
```

`azd up` will prompt for an environment name and a location, then:

1. Provision the resource group, Log Analytics, Storage (queue + table), Container Registry,
   managed identity, Container Apps environment, and the worker Container App (via `infra/`).
2. Build the worker image from the root `Dockerfile`, push it to the provisioned ACR, and
   deploy it to the Container App.

When it finishes, `azd` prints the resource names. You can re-read them anytime with:

```pwsh
azd env get-values
```

## Image size: lightweight vs. ~3 GB

The customer's real worker image is ~3 GB, and that size is the reason they use a regular
Container App (warm replicas) instead of ACA Jobs — a 3 GB pull/cold-start on every Job
execution would exceed their 30-second tolerance. See the root `README.md` ("Why Apps, not
Jobs"). The build supports both modes:

```pwsh
# Lightweight (default) — fast local/CI builds:
docker build --platform linux/amd64 -t worker:lite .

# Inflated to ~3 GB — to measure realistic pull/cold-start timing:
docker build --platform linux/amd64 --build-arg IMAGE_PADDING_GB=3 -t worker:fat .
docker images worker            # confirm the ~3 GB size
```

The padding is a single incompressible layer and does **not** change worker behavior or logs.
For `azd`-driven deploys you can pass the build arg via `azure.yaml` `docker.buildArgs` or build
and push the fat image manually, then point the Container App at that tag.

> **ACA runs x86/amd64 only.** Always build with `--platform linux/amd64` — important on ARM
> hosts (Apple Silicon, Windows on ARM), where a native build produces an arm64 image that will
> not run on Container Apps. `azd` enforces this via `platform: linux/amd64` in `azure.yaml`.
>
> On an ARM host, the amd64 build runs under emulation (QEMU) and the .NET restore/publish steps
> can take several minutes (and longer for the ~3 GB padded image). This is expected; the build
> is correct, just slow. To avoid emulation entirely you can build on an x86 machine or use
> `az acr build --platform linux/amd64` to build in the cloud.

## Run the worker locally (optional)

You can exercise the worker against [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)
without deploying:

```pwsh
# Terminal 1: start Azurite
docker run -p 10000:10000 -p 10001:10001 mcr.microsoft.com/azure-storage/azurite

# Terminal 2: run the worker against Azurite
$env:STORAGE_CONNECTION_STRING = "UseDevelopmentStorage=true"
dotnet run --project src/Worker

# Terminal 3: enqueue a quick smoke batch
dotnet run --project src/Enqueuer -- --connection "UseDevelopmentStorage=true" --preset smoke
```

Next: see [repro.md](repro.md) to run a reproduction.
