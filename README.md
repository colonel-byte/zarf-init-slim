# Zarf Package, init-slim

This is a vanilla-compatible slim package of the upstream Zarf init components, excluding the `k3s` component. The package is named `init-slim`, which is the name it shows up under in `zarf package list`.

All components are made optional to allow deploying different components slowly over the course of an install.

The package uses the `zarf.dev/v1beta1` API and composes the upstream component configs published at `oci://ghcr.io/zarf-dev/components/init/*`. Configuration is done with **values**, not deploy variables: either a values file (`zarf package deploy -v my-values.yaml`) or `--set-values key.path=value`. Each component exposes its chart under a top-level key - `registry` (the base for both registries), `seedRegistry` (overrides on top of `registry`, for the ephemeral one), `agent`, and `gitServer`.

## Using an S3-Compatible Storage Backend (e.g., Rook-Ceph OBC)

Per [zarf#5312](https://github.com/zarf-dev/zarf/pull/5312), the registry image uses the standard `s3` storage driver from environment variables, requiring no custom init package builds.

To wire the registry into an S3 bucket (such as the `registry-bucket` created by `zarf-csi-rook-ceph`):

1. Set `registry.persistence.enabled: false` (required so the chart does not define a filesystem storage driver alongside S3).
2. Pass S3 configuration through `registry.extraEnvVars`.

### Example values file for Rook-Ceph:

```yaml
registry:
  persistence:
    enabled: false
  extraEnvVars:
    - name: REGISTRY_STORAGE_S3_REGION
      value: "us-east-1"
    - name: REGISTRY_STORAGE_S3_BUCKET
      value: "registry-bucket"
    - name: REGISTRY_STORAGE_S3_REGIONENDPOINT
      value: "http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc.cluster.local:8080"
    - name: REGISTRY_STORAGE_S3_FORCEPATHSTYLE
      value: "true"
    - name: REGISTRY_STORAGE_S3_SECURE
      value: "false"
    - name: REGISTRY_STORAGE_REDIRECT_DISABLE
      value: "true"
    - name: REGISTRY_STORAGE_S3_ACCESSKEY
      valueFrom:
        secretKeyRef:
          name: registry-bucket
          key: AWS_ACCESS_KEY_ID
    - name: REGISTRY_STORAGE_S3_SECRETKEY
      valueFrom:
        secretKeyRef:
          name: registry-bucket
          key: AWS_SECRET_ACCESS_KEY
```

Deploy it with `zarf package deploy ... -v s3-values.yaml`, or point `package.deploy.values` at it in your `zarf-config.yaml`.

Any other `storage.s3` setting from the [distribution docs](https://distribution.github.io/distribution/storage-drivers/s3/) can be passed the same way, for example `REGISTRY_STORAGE_S3_V4AUTH`, `REGISTRY_STORAGE_S3_CHUNKSIZE`, `REGISTRY_STORAGE_S3_MULTIPARTCOPYCHUNKSIZE`, `REGISTRY_STORAGE_S3_MULTIPARTCOPYTHRESHOLDSIZE`, and `REGISTRY_STORAGE_S3_MULTIPARTCOPYMAXCONCURRENCY`. Settings left unset use the distribution defaults.

### High-Availability Settings (optional)

When using S3 storage, the registry does not require a `ReadWriteMany` volume for multi-replica operation. Scaling is configured with values:

```yaml
registry:
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 7
```

Replicas are already spread across nodes: `values/init-slim.yaml` sets a preferred `podAntiAffinity` on `kubernetes.io/hostname`.

## Settings Preset in `values/init-slim.yaml`

`values/init-slim.yaml` ships with the package and is applied after the upstream component defaults, so it decides these keys unless you override them at deploy time:

| Value path                                                             | What it does                                                                                                         |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `registry.tolerations`, `registry.proxy.tolerations`                   | `operator: Exists` - registry and its proxy tolerate any taint                                                       |
| `registry.affinity.enabled`, `registry.affinity.custom`                | Registry pods only schedule onto nodes labelled `adrp.xyz/is-infra=true`, and prefer to spread across hosts          |
| `registry.serviceAccount`                                              | Creates a `docker-registry` service account                                                                          |
| `agent.tolerations`                                                    | `operator: Exists` for the Zarf agent                                                                                |
| `seedRegistry.persistence.enabled`, `seedRegistry.autoscaling.enabled` | `false` - the seed registry is torn down once the permanent one is up, so it provisions no volume and does not scale |

The infrastructure node label is baked in at `adrp.xyz/is-infra`. **Label the nodes first**, or override `registry.affinity.custom` at deploy time, or the registry will not schedule.
