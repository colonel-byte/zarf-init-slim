<!--
Filed against: zarf-dev/zarf - template: bug_report.md - label: possible-bug 🐛
Suggested title: v1beta1: a chart `values` mapping changes the package values tree and leaks nested keys into later components
-->

### Environment
Device and OS: Fedora Linux 44, `Linux 7.2.11-200.fc44.x86_64 x86_64`
App version: `v0.89.0`
Kubernetes distro being used: none. The problem occurs during `package create` and `package inspect`.
Other: The package uses `apiVersion: zarf.dev/v1beta1`. The published v1beta1 init components at `oci://ghcr.io/zarf-dev/components/init/*:v0.89.0` also show the problem.

### Steps to reproduce

1. Make a chart in the `chart/` directory.

   `chart/Chart.yaml`
   ```yaml
   apiVersion: v2
   name: demo
   version: 0.1.0
   ```

   `chart/values.yaml`
   ```yaml
   fromShared: ""
   nested:
     both: ""
   ```

   `chart/templates/cm.yaml`
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: demo
   data:
     both: "{{ .Values.nested.both }}"
   ```

2. Make a values file. The key `nested.both` must be in **both** source paths.

   `values.yaml`
   ```yaml
   shared:
     fromShared: shared-value
     nested:
       both: from-shared
   extra:
     nested:
       both: from-extra
   ```

3. Make two component configs, `comp-a.yaml` and `comp-b.yaml`. The two files are the same except for `metadata.name`. Each file maps `.shared` and no other path.

   ```yaml
   apiVersion: zarf.dev/v1beta1
   kind: ZarfComponentConfig
   metadata:
     name: comp-a   # comp-b in the second file
   component:
     charts:
       - name: demo
         namespace: demo
         local:
           path: chart
         values:
           - sourcePath: .shared
             targetPath: .
   ```

4. Make a package. Only the **first** component adds a second mapping.

   `zarf.yaml`
   ```yaml
   apiVersion: zarf.dev/v1beta1
   kind: ZarfPackageConfig
   metadata:
     name: values-leak
     version: 0.1.0
   values:
     files:
       - values.yaml
   components:
     - name: comp-a
       import:
         local:
           - path: comp-a.yaml
       charts:
         - name: demo
           values:
             - sourcePath: .extra
               targetPath: .
     - name: comp-b
       import:
         local:
           - path: comp-b.yaml
   ```

5. Create the package. Then inspect it two times.

   ```console
   zarf package create --confirm . -o .
   zarf package inspect values-files zarf-package-values-leak-amd64-0.1.0.tar.zst
   zarf package inspect values-files zarf-package-values-leak-amd64-0.1.0.tar.zst --components comp-b
   ```

6. Deploy the package to a cluster. Then read the value each chart received.

   ```console
   zarf package deploy zarf-package-values-leak-amd64-0.1.0.tar.zst --confirm --connected
   kubectl -n comp-a get configmap demo -o jsonpath='{.data.both}'
   kubectl -n comp-b get configmap demo -o jsonpath='{.data.both}'
   ```

### Expected result

`comp-b` does not map `.extra`. `comp-b` must resolve `nested.both` to `from-shared` in all cases. The result must be the same when Zarf renders `comp-a` in the same command. A chart `values[]` mapping must not change the values of a different component.

### Actual Result

Zarf renders the full package. `comp-b` resolves `nested.both` to `from-extra`, but `comp-b` does not map `.extra`.

Zarf renders `comp-b` alone. `comp-b` resolves `nested.both` to `from-shared`, which is correct. The result changes with the set of components in the command.

A deployment gives the same wrong result. `comp-b` receives `from-extra` on the cluster.

The problem changes only nested map keys. It changes only the components that come after the component with the extra mapping. Zarf copies a top-level key correctly if that key is in only one source path. For this reason, a simple test case does not show the problem.

### Visual Proof (screenshots, videos, text, etc)

```console
$ zarf package inspect values-files zarf-package-values-leak-amd64-0.1.0.tar.zst
# associated chart: demo
fromShared: shared-value
nested:
  both: from-extra        # comp-a: correct
---
# associated chart: demo
fromShared: shared-value
nested:
  both: from-extra        # comp-b: WRONG
---

$ zarf package inspect values-files zarf-package-values-leak-amd64-0.1.0.tar.zst --components comp-b
# associated chart: demo
fromShared: shared-value
nested:
  both: from-shared       # correct when rendered alone
```

On a cluster, after `zarf package deploy --confirm --connected`:

```console
$ kubectl -n comp-a get configmap demo -o jsonpath='{.data.both}'
from-extra        # comp-a: correct

$ kubectl -n comp-b get configmap demo -o jsonpath='{.data.both}'
from-extra        # comp-b: WRONG, it must be from-shared
```

### Severity/Priority

High for users who compose the v1beta1 init components. The wrong values reach the cluster. Zarf gives no warning. An inspection of one component gives the correct result. Therefore, only an inspection of the full package shows the problem.

There is also no safe method to configure the seed registry and the permanent registry differently. `zarf-seed-registry` and `zarf-registry` both map `.registry` to `.` on a chart with the name `docker-registry`. The obvious method is to give the seed registry a different values path:

```yaml
- name: zarf-seed-registry
  import:
    remote:
      - url: oci://ghcr.io/zarf-dev/components/init/zarf-seed-registry:v0.89.0
  charts:
    - name: docker-registry
      values:
        - sourcePath: .seedRegistry
          targetPath: .
```

Set `seedRegistry.persistence.enabled: false` and `seedRegistry.autoscaling.enabled: false`. This also disables persistence and autoscaling for the **permanent** registry. The keys `persistence` and `autoscaling` are nested maps, and they are also in `.registry`.

### Additional Context

Possible cause: Zarf merges the source subtree into the target by reference. It does not make a deep copy. The merge for the first component then writes into maps that the package values tree still holds. Two facts indicate a shallow copy in the values resolution path: the problem depends on component order, and it changes only nested keys.

I confirmed the problem with `zarf package inspect values-files` and with `zarf package deploy` against a k3d cluster. Both give the same wrong value for `comp-b`. The script at [`test/values-aliasing/run.sh`](test/values-aliasing/run.sh) in this repository runs the full reproduction: it creates a k3d cluster, deploys the package, reads both ConfigMaps, and exits 0 when the problem is present.
