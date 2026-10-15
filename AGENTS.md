# AGENTS.md

## Overview
This repository defines **zarf-init-slim** (`metadata.name: init-slim`, as shown by `zarf package list`), a vanilla-compatible slim package of the upstream `ghcr.io/zarf-dev/packages/init` Zarf package without the `k3s` component.

All components are optional to allow staged deployments (e.g., seeding a cluster first, deploying storage providers, and then deploying the full registry, agent, and git server).

## Repository Layout
- `zarf.yaml`: Main package definition importing upstream `init` components (`zarf-injector`, `zarf-seed-registry`, `zarf-registry`, `zarf-agent`, `git-server`).
- `injector/`: Custom injector manifests/assets for architectures such as `arm64`.
- `values/`:
  - `registry-core.yaml`: Base settings for the Docker registry (tolerations, node affinity, pod anti-affinity, resource limits, service account). Applied after the upstream values file, so every key here overrides the matching upstream deploy variable (`REGISTRY_CPU_REQ`, `REGISTRY_MEM_*`, `REGISTRY_TOLERATIONS`, `REGISTRY_AFFINITY_*`, `REGISTRY_SERVICE_ACCOUNT_*`) and makes it inert. Do NOT add keys here that users are expected to set at deploy time (notably `autoscaling` and `extraEnvVars`).
  - `registry-seed.yaml`: Ephemeral settings for the seed registry (`zarf-seed-registry`).
- `zarf-config.yaml`: Configuration for pinning image domains and tags during package creation.
- `.github/workflows/`:
  - `release.yml`: Multi-architecture release workflow (`amd64`, `arm64`).
  - `nixflake-update.yml`: Flake input updater workflow.
- `.github/renovate.json5`: Renovate configuration tracking upstream package tags and images.

## Storage Architecture & Guidelines
1. **No Package Flavors:**
   - The package is unified on `main` without flavors (`upstream`, `rook`, `cloud`).
2. **S3 / Object Storage Integration:**
   - Per upstream Zarf PR [#5312](https://github.com/zarf-dev/zarf/pull/5312), the registry uses the `s3` storage driver purely through environment variables at deploy-time.
   - Do NOT bake custom S3 Helm values files into `zarf.yaml`.
   - To back the registry with an S3-compatible bucket (e.g. Rook-Ceph ObjectBucketClaim `registry-bucket`):
     - Pass `REGISTRY_PVC_ENABLED: "false"` to prevent the filesystem storage driver from being configured.
     - Pass the S3 driver parameters via `REGISTRY_EXTRA_ENVS` (region, bucket, regionendpoint, forcepathstyle, credentials via `valueFrom.secretKeyRef`).
3. **Verification Commands:**
   - Linting: `ZARF_CONFIG=zarf-config.yaml zarf dev lint .`
   - Renovate config: `npx --yes renovate-config-validator .github/renovate.json5`
   - Creation test: `zarf package create --confirm .`
