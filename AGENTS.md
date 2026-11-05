# AGENTS.md

## Overview
This repository defines **zarf-init-slim** (`metadata.name: init-slim`, as shown by `zarf package list`), a vanilla-compatible slim package of the upstream Zarf init components without the `k3s` component. It uses the `zarf.dev/v1beta1` API.

All components are optional to allow staged deployments (e.g., seeding a cluster first, deploying storage providers, and then deploying the full registry, agent, and git server).

## Repository Layout
- `zarf.yaml`: Main package definition. Each component imports an upstream component config from `oci://ghcr.io/zarf-dev/components/init/<name>:<zarf version>` (`zarf-injector`, `zarf-seed-registry`, `zarf-registry`, `zarf-agent`, `git-server`), marks it `optional: true`, and overrides images by `id` so renovate can bump them independently of the zarf release.
- `values/init-slim.yaml`: Package values, declared via `values.files` in `zarf.yaml`. Keyed by the value path each component exposes: `registry` (shared by BOTH registries), `agent`, `gitServer`. Applied after the upstream component defaults. Do NOT add keys here that users are expected to set at deploy time (notably `autoscaling`, `persistence` and `extraEnvVars`).
- `zarf-config.yaml`: CLI config only (log format, OCI concurrency). Image pinning lives in `zarf.yaml` now; v1beta1 components ship pre-rendered, so there are no `###ZARF_PKG_TMPL_*###` values to set at create time.
- `.github/workflows/`:
  - `release.yml`: Multi-architecture release workflow (`amd64`, `arm64`).
  - `nixflake-update.yml`: Flake input updater workflow.
- `.github/renovate.json5`: Renovate configuration tracking upstream package tags and images.
- `zarf-v1beta1-values-aliasing.md`: Bug report for upstream Zarf, written to the `bug_report.md` issue template. A chart `values[]` mapping on one component changes the values another component's chart receives. This is why the seed registry has no settings of its own in `values/init-slim.yaml`.
- `test/values-aliasing/`: End-to-end reproduction for that bug. `run.sh` creates a throwaway k3d cluster, deploys the package in `package/`, reads back the ConfigMap each chart rendered, and exits 0 when the wrong value reached the cluster. `k3d-config.yaml` is a verbatim copy of the one in `colonel-byte/uds-bundles` - refresh it from upstream rather than editing it for a test.

## Storage Architecture & Guidelines
1. **No Package Flavors:**
   - The package is unified on `main` without flavors (`upstream`, `rook`, `cloud`).
2. **S3 / Object Storage Integration:**
   - Per upstream Zarf PR [#5312](https://github.com/zarf-dev/zarf/pull/5312), the registry uses the `s3` storage driver purely through environment variables at deploy-time.
   - Do NOT bake custom S3 Helm values into `values/init-slim.yaml`.
   - To back the registry with an S3-compatible bucket (e.g. Rook-Ceph ObjectBucketClaim `registry-bucket`):
     - Set `registry.persistence.enabled: false` to prevent the filesystem storage driver from being configured.
     - Pass the S3 driver parameters via `registry.extraEnvVars` (region, bucket, regionendpoint, forcepathstyle, credentials via `valueFrom.secretKeyRef`).
     - Both go in a deploy-time values file (`zarf package deploy -v s3-values.yaml`) or `--set-values`, not in `values/init-slim.yaml`.
3. **Verification Commands:**
   - Linting: `ZARF_CONFIG=zarf-config.yaml zarf dev lint .`
   - Renovate config: `npx --yes renovate-config-validator .github/renovate.json5`
   - Definition check: `ZARF_CONFIG=zarf-config.yaml zarf dev inspect definition .`
   - Creation test: `zarf package create --confirm . --architecture amd64` (and `arm64`)
   - Rendered chart values: `zarf package inspect values-files zarf-init-amd64-*.tar.zst`
   - Values aliasing reproduction: `./test/values-aliasing/run.sh` (needs k3d, kubectl, docker; skips with a reason when one is missing)

## Removing the values-aliasing workaround

The seed registry has no settings of its own because of the upstream bug in [`zarf-v1beta1-values-aliasing.md`](zarf-v1beta1-values-aliasing.md). When that bug is fixed, three things come out of the repo and one thing goes back in. Do all four together: the files are the only record of why the seed registry is configured the way it is.

Check first. `./test/values-aliasing/run.sh` prints `NOT REPRODUCED` and exits 1 on a zarf that carries the fix, which is the whole point of the script. A passing run (exit 0) means the bug is still there and nothing below should be done.

1. Delete `test/values-aliasing/` and `zarf-v1beta1-values-aliasing.md`.
2. Delete the two `Repository Layout` entries for them, the `Values aliasing reproduction` line under `Verification Commands`, and this section.
3. Give the seed registry its own values path again in `zarf.yaml`, so that an ephemeral registry stops provisioning a 20Gi volume:

   ```yaml
   - name: zarf-seed-registry
     optional: true
     import:
       remote:
         # renovate: datasource=docker
         - url: oci://ghcr.io/zarf-dev/components/init/zarf-seed-registry:v0.89.0
     charts:
       - name: docker-registry
         values:
           - sourcePath: .seedRegistry
             targetPath: .
   ```

   With the matching block in `values/init-slim.yaml`:

   ```yaml
   seedRegistry:
     persistence:
       enabled: false
     autoscaling:
       enabled: false
   ```

4. Prove the fix held. Build the package and read both registries back:

   ```console
   zarf package create --confirm . --architecture amd64
   zarf package inspect values-files zarf-init-amd64-*.tar.zst --components zarf-seed-registry
   zarf package inspect values-files zarf-init-amd64-*.tar.zst --components zarf-registry
   ```

   The seed registry must report `persistence.enabled: false` and the permanent registry must report `persistence.enabled: true`. Run the same two commands without `--components` as well: reading the full package is what exposed the bug in the first place, and a per-component check alone would have missed it.

Upstream components other than the registry may gain their own values paths in the same release. If `zarf-seed-registry` starts mapping something other than `.registry`, prefer that over the remap above and delete the `seedRegistry` block.

## Dependency Updates

Every zarf dependency in this repo is pinned to the same version and must stay that way: the CLI version in `.github/workflows/release.yml`, `metadata.version` in `zarf.yaml`, the five `oci://ghcr.io/zarf-dev/components/init/*` import URLs, and the agent image. They are all cut from one upstream release.

The `Zarf packages` rule in [`.github/renovate.json5`](.github/renovate.json5) groups them into a single PR. It spans two datasources, because the component configs and the agent image are OCI artifacts (`docker`) while the CLI is a release asset (`github-releases`).

Grouping across datasources means renovate holds the whole group until an update exists on both sides. That is deliberate. A half-applied bump would build the package with a CLI that does not match the component configs it imports, and v1beta1 composition is resolved at create time, so the mismatch would land in a published package rather than failing loudly. A group PR that stalls is the signal that upstream has drifted - investigate it, do not split it.

When adding a new zarf dependency, add it to `matchPackageNames` in that rule. When adding any other versioned reference, give it a `# renovate: datasource=... depName=...` comment on the line above: the custom manager in the same file reads those comments and nothing else.

## Writing style

Use `-` (hyphen), not `—` (em dash), wherever a hyphen reads fine.

Markdown is not hard-wrapped: write a paragraph or a list item on one continuous line and let the renderer wrap it. That rule, with examples, is in [`docs/AGENTS.md`](docs/AGENTS.md) and [`ansible/AGENTS.md`](ansible/AGENTS.md). The table rule is here, because it applies to every Markdown file in the tree, including this one.

### Pad table cells so the columns line up

Tables are written in their aligned form, so that the source reads as a table and a reviewer can see the columns without rendering the file. Pad every cell with spaces to the width of the widest cell in its column, keep one space of padding inside each pipe, and run the dashes of the delimiter row out to that same width. Every line of the table then has the same length.

Write this:

```markdown
| Path                                   | What it holds     |
| -------------------------------------- | ----------------- |
| `.spec.config.registries[N].auth.user` | Registry username |
```

Not this:

```markdown
| Path | What it holds |
| --- | --- |
| `.spec.config.registries[N].auth.user` | Registry username |
```

Adding a row that is wider than the column repads the whole table, which is expected - the alignment is part of the content, not a one-time cleanup.

The `pad-markdown-tables` pre-commit hook does this for you: [`hack/markdown-tables.py`](hack/markdown-tables.py) repads every table in the files being committed and touches nothing else -- no rewrapping, no normalised bullets or emphasis. It skips tables inside fenced code blocks, which is what keeps the unaligned example above an example rather than something the hook quietly aligns. A second hook, `markdown-tables-self-check`, asserts that: `markdown-tables.py --self-check` runs a fenced example through the formatter and fails if it came out changed.
