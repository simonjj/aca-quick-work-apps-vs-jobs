# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build stage
#
# Pinned to the build host's native architecture ($BUILDPLATFORM) so the .NET
# compile/publish runs natively even when the final image targets a different
# platform (e.g. building a linux/amd64 image on an arm64 dev machine). `dotnet
# publish` without a RID emits portable IL that runs on the amd64 runtime below,
# so no QEMU emulation of the build is required — only fast.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY src/Worker/Worker.csproj src/Worker/
RUN dotnet restore src/Worker/Worker.csproj

COPY src/Worker/ src/Worker/
RUN dotnet publish src/Worker/Worker.csproj -c Release -o /app/publish /p:UseAppHost=false

# ---------------------------------------------------------------------------
# Padding stage
#
# Generates the image-size padding on the NATIVE build host ($BUILDPLATFORM) so the
# multi-GB write isn't QEMU-emulated when cross-building a linux/amd64 image on arm64.
# The bytes come from /dev/urandom: incompressible, so they add real on-disk/registry
# bytes (and real pull time) rather than compressing away. The content is random (not
# reproducible) but its SIZE is deterministic — which is all the cold-start benchmark needs.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM busybox:1.36 AS padding
ARG IMAGE_PADDING_GB=0
RUN if [ "${IMAGE_PADDING_GB}" != "0" ]; then \
        echo "Generating ${IMAGE_PADDING_GB} GB of incompressible padding (native build host)..."; \
        head -c $(( ${IMAGE_PADDING_GB} * 1024 * 1024 * 1024 )) /dev/urandom > /padding.bin; \
        ls -lh /padding.bin; \
    else \
        echo "No padding (lightweight image)."; \
        : > /padding.bin; \
    fi

# ---------------------------------------------------------------------------
# Runtime stage (amd64 target for ACA)
# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/runtime:8.0 AS final
WORKDIR /app

# Image size control.
#
# The customer's real worker image is ~3 GB, and that size is the reason they run a regular
# Azure Container App (warm replicas) instead of ACA Jobs: pulling/cold-starting a 3 GB image
# on every Job execution would push start-up past their 30-second tolerance. This template
# reproduces that pull cost so the App-vs-Jobs cold-start benchmark is representative.
#
# Default build is lightweight for fast local iteration and CI. azd sets IMAGE_PADDING_GB=3
# by default (see azure.yaml) to reproduce the real image size; override with:
#
#   docker build --build-arg IMAGE_PADDING_GB=3 -t worker:fat .
#   azd env set IMAGE_PADDING_GB 0   # fast, lightweight image
#
# The padding lands as its own layer here via COPY so it adds real registry/pull bytes.
COPY --from=padding /padding.bin /app/padding.bin

COPY --from=build /app/publish .

# CONTAINER_APP_REPLICA_NAME (App) / CONTAINER_APP_JOB_EXECUTION_NAME (Job) are injected by ACA
# at runtime and used in logs/state records to identify the replica or execution.
ENV DOTNET_TieredPGO=1
ENTRYPOINT ["dotnet", "Worker.dll"]
