# Zarf Package, init-slim

This is a vanilla-compatible slim package of the upstream `ghcr.io/zarf-dev/packages/init`, excluding the `k3s` component. The package is named `init-slim`, which is the name it shows up under in `zarf package list`.

All components are made optional to allow deploying different components slowly over the course of an install.

## Using an S3-Compatible Storage Backend (e.g., Rook-Ceph OBC)

Per [zarf#5312](https://github.com/zarf-dev/zarf/pull/5312), the registry image uses the standard `s3` storage driver from environment variables, requiring no custom init package builds.

To wire the registry into an S3 bucket (such as the `registry-bucket` created by `zarf-csi-rook-ceph`):

1. Set `REGISTRY_PVC_ENABLED: "false"` (required so the chart does not define a filesystem storage driver alongside S3).
2. Pass S3 configuration through `REGISTRY_EXTRA_ENVS`.

### Example `zarf-config.yaml` for Rook-Ceph:

```yaml
package:
  deploy:
    set:
      REGISTRY_PVC_ENABLED: "false"
      REGISTRY_EXTRA_ENVS: |
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

Any other `storage.s3` setting from the [distribution docs](https://distribution.github.io/distribution/storage-drivers/s3/) can be passed the same way, for example `REGISTRY_STORAGE_S3_V4AUTH`, `REGISTRY_STORAGE_S3_CHUNKSIZE`, `REGISTRY_STORAGE_S3_MULTIPARTCOPYCHUNKSIZE`, `REGISTRY_STORAGE_S3_MULTIPARTCOPYTHRESHOLDSIZE`, and `REGISTRY_STORAGE_S3_MULTIPARTCOPYMAXCONCURRENCY`. Settings left unset use the distribution defaults.

### High-Availability Settings (optional)

When using S3 storage, the registry does not require a `ReadWriteMany` volume for multi-replica operation. Scaling is configured via deploy config:

```yaml
package:
  deploy:
    set:
      REGISTRY_HPA_ENABLE: "true"
      REGISTRY_HPA_MIN: "3"
      REGISTRY_HPA_MAX: "7"
```

Replicas are already spread across nodes: `values/registry-core.yaml` sets a preferred `podAntiAffinity` on `kubernetes.io/hostname`.

## Settings Fixed in `values/registry-core.yaml`

`values/registry-core.yaml` is applied on top of the upstream registry values, so the keys it sets win over the matching deploy variables. These upstream variables therefore have **no effect** on this package and must be changed in `values/registry-core.yaml` instead:

| Fixed key        | Inert upstream variable                                                                                    |
| ---------------- | ---------------------------------------------------------------------------------------------------------- |
| `resources`      | `REGISTRY_CPU_REQ`, `REGISTRY_MEM_REQ`, `REGISTRY_CPU_LIMIT`, `REGISTRY_MEM_LIMIT`                         |
| `tolerations`    | `REGISTRY_TOLERATIONS`                                                                                     |
| `affinity`       | `REGISTRY_AFFINITY_ENABLE`, `REGISTRY_AFFINITY_CUSTOM`                                                     |
| `serviceAccount` | `REGISTRY_CREATE_SERVICE_ACCOUNT`, `REGISTRY_SERVICE_ACCOUNT_NAME`, `REGISTRY_SERVICE_ACCOUNT_ANNOTATIONS` |

Everything else upstream exposes (including `REGISTRY_PVC_ENABLED`, `REGISTRY_EXTRA_ENVS`, and the `REGISTRY_HPA_*` variables above) still works through `package.deploy.set`.

## Package Variables

| Variable                    | Default                | Notes                                                                                                                                                      |
| --------------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NODE_INFRASTRUCTURE_LABEL` | `adrp.xyz/is-infra`    | Node label used for the registry node affinity. Registry pods only schedule onto nodes labelled `<label>=true`, so label the nodes first or override this. |
| `AGENT_TOLERATIONS`         | `- operator: "Exists"` | Tolerations for the Zarf agent.                                                                                                                            |
| `PROXY_TOLERATIONS`         | `- operator: "Exists"` | Tolerations for the registry proxy and injector.                                                                                                           |
