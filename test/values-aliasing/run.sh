#!/usr/bin/env bash
# Proves, on a real cluster, the bug written up in zarf-v1beta1-values-aliasing.md at the
# repository root: a chart `values[]` mapping on one component changes the values a second
# component's chart receives.
#
# comp-b maps `.shared` and nothing else, so its ConfigMap must read `from-shared`. If it
# reads `from-extra`, comp-a's extra mapping reached it and the bug is present at deploy
# time, not only in `zarf package inspect values-files`.
#
# Exit 0 means the bug reproduced. Exit 1 means it did not, which is what a fixed zarf
# looks like - read the output rather than the status alone.
#
# The cluster is created and deleted by this script. It refuses to touch a cluster that
# already exists, so it cannot delete one you are using.
#
# A `--connected` deploy logs one "namespaces \"zarf\" not found" error before it creates
# that namespace itself. It is upstream noise, not a failure of this test.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cluster="$(yq '.metadata.name' "$here/k3d-config.yaml")"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

skip() {
  echo "SKIP: $*"
  exit 0
}

for tool in zarf k3d kubectl yq docker; do
  command -v "$tool" >/dev/null || skip "$tool is not installed"
done
docker info >/dev/null 2>&1 || skip "docker is not running"

# zarf below v0.88.0 has no v1beta1 support, so the package will not build.
want=v0.88.0
have="$(zarf version)"
[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -1)" = "$want" ] ||
  skip "zarf $have is older than $want, which is the floor for v1beta1"

k3d cluster list "$cluster" >/dev/null 2>&1 &&
  skip "a k3d cluster named '$cluster' already exists; delete it first"

run() { # run <logfile> <command...>, printing the log only when the command fails
  local log="$workdir/$1"; shift
  "$@" >"$log" 2>&1 || { cat "$log"; return 1; }
}

echo "== creating cluster '$cluster'"
run cluster.log k3d cluster create --config "$here/k3d-config.yaml"
trap 'k3d cluster delete "$cluster" >/dev/null 2>&1 || true; rm -rf "$workdir"' EXIT
run wait.log kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo "== building and deploying the reproduction package"
run create.log zarf package create "$here/package" --confirm -o "$workdir"
# --connected skips the registry, so the package needs no `zarf init` to deploy.
run deploy.log zarf package deploy "$workdir"/zarf-package-values-aliasing-*.tar.zst --confirm --connected

a="$(kubectl -n comp-a get configmap demo -o jsonpath='{.data.both}')"
b="$(kubectl -n comp-b get configmap demo -o jsonpath='{.data.both}')"

echo
echo "comp-a (maps .shared and .extra) expected from-extra,  got $a"
echo "comp-b (maps .shared only)       expected from-shared, got $b"
echo

[ "$a" = "from-extra" ] || {
  echo "INCONCLUSIVE: comp-a did not take its own mapping, so the package is not set up as the report describes"
  exit 1
}

if [ "$b" = "from-extra" ]; then
  echo "BUG REPRODUCED: comp-b received comp-a's value at deploy time"
  exit 0
fi

echo "NOT REPRODUCED: comp-b kept its own value. This zarf may carry the fix."
exit 1
