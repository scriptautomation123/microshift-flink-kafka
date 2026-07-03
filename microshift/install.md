# MicroShift Install (Ubuntu + MINC)

## Installation Goals

1. Prepare host packages for networking diagnostics and container runtime support.
2. Install and validate Podman.
3. Install and validate `oc` and `kubectl`.
4. Install and validate MINC.
5. Set MINC defaults and bootstrap a local cluster.

## 1. Host Prerequisites

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates \
  conntrack \
  curl \
  iptables \
  jq \
  nftables \
  uidmap \
  podman
```

## 2. Validate Podman

```bash
podman info --format '{{.Host.NetworkBackend}} {{.Host.Security.Rootless}}'
```

## 3. Install OpenShift Client (`oc`, `kubectl`)

```bash
arch=$(uname -m)
case "$arch" in
  x86_64) oc_arch="amd64" ;;
  aarch64|arm64) oc_arch="arm64" ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

version="4.19.0"
base_url="https://mirror.openshift.com/pub/openshift-v4/${oc_arch}/clients/ocp/${version}"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

cd "$workdir"
curl -fsSLO "$base_url/openshift-client-linux-${version}.tar.gz"
tar -xzf "openshift-client-linux-${version}.tar.gz"
mkdir -p "$HOME/.local/bin"
install -m 0755 oc "$HOME/.local/bin/oc"
install -m 0755 kubectl "$HOME/.local/bin/kubectl"
```

Validate:

```bash
bash -lc 'command -v oc && oc version --client'
```

## 4. Install MINC

```bash
curl -fsSL -o /tmp/minc https://github.com/minc-org/minc/releases/download/v0.1.0/minc-linux-amd64
sudo install -m 0755 /tmp/minc /usr/local/bin/minc
minc version
```

For arm64, use the matching release asset.

## 5. Set MINC Defaults

```bash
minc config set provider podman
minc config set allow-rootless true
minc config view
```

Important note:

- In validated setups, MINC may still run under rootful Podman even with `allow-rootless=true`.
- Always validate runtime behavior directly instead of assuming config alone is authoritative.

## 6. Create Cluster

```bash
minc delete || true
minc create
```

Validate:

```bash
minc status
minc list
```

## 7. Initial Cluster Health Checks

```bash
export PATH="$HOME/.local/bin:$PATH"
oc whoami
oc whoami --show-server
oc get nodes -o wide
oc get pods -A
oc get pods -n openshift-operator-lifecycle-manager -o wide
ss -ltnp | grep -E ':(6443|9080|9443)\b' || true
```

## Next Step

Continue with `configure.md` for DNS hardening, Docker coexistence forwarding, and troubleshooting.

For local Kafka/Flink workloads, `configure.md` also includes static local PV provisioning to avoid PVC `Pending` on clusters without a default dynamic `StorageClass`.
