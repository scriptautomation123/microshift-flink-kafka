# MicroShift Configure And Operate (Ubuntu + MINC)

## Quick Start

If Docker is running:

1. Configure Podman DNS.
2. Validate rootful Podman DNS and egress.
3. Install `DOCKER-USER` forwarding exceptions for `podman0`.
4. Recreate MINC cluster.
5. Provision local static PVs for Kafka and Flink namespaces (recommended for local MINC).
6. Validate `oc`, node readiness, ingress listeners, and OLM pod health.

If Docker is not running:

1. Configure Podman DNS.
2. Validate rootful Podman DNS and egress.
3. Recreate MINC cluster.
4. Provision local static PVs for Kafka and Flink namespaces (recommended for local MINC).
5. Validate `oc`, node readiness, ingress listeners, and OLM pod health.

## 1. Configure Podman DNS (Rootful)

Preferred script path:

```bash
sudo scripts/configure-podman-dns.sh 1.1.1.1 8.8.8.8
```

Manual path:

```bash
sudo install -d -m 0755 /etc/containers
sudo tee /etc/containers/containers.conf >/dev/null <<'EOF'
[containers]
dns_servers = ["1.1.1.1", "8.8.8.8"]
EOF
```

Optional user-level alignment:

```bash
mkdir -p "$HOME/.config/containers"
cat > "$HOME/.config/containers/containers.conf" <<'EOF'
[containers]
dns_servers = ["1.1.1.1", "8.8.8.8"]
EOF
```

Validate DNS file seen by rootful Podman:

```bash
sudo podman run --rm docker.io/library/alpine:3.20 cat /etc/resolv.conf
```

## 2. Validate Podman Runtime Egress

```bash
sudo podman run --rm docker.io/library/busybox:1.36 sh -c 'nslookup quay.io 1.1.1.1; echo ---; wget -T 10 -O- http://1.1.1.1 2>&1 | sed -n "1,20p"'
```

If this fails while Docker is healthy, apply forwarding exceptions.

## 3. Docker + Podman Coexistence Hardening

Preferred script path:

```bash
sudo scripts/install-docker-podman-forwarding.sh
```

Manual live fix:

```bash
sudo iptables -C DOCKER-USER -i podman0 -j ACCEPT 2>/dev/null || sudo iptables -I DOCKER-USER 1 -i podman0 -j ACCEPT
sudo iptables -C DOCKER-USER -o podman0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || sudo iptables -I DOCKER-USER 2 -o podman0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

## 4. Recreate Cluster After Runtime Changes

```bash
minc delete || true
minc create
```

Validate:

```bash
minc status
minc list
```

## 5. Cluster Validation

```bash
export PATH="$HOME/.local/bin:$PATH"
oc whoami
oc whoami --show-server
oc get nodes -o wide
oc get pods -A
oc get pods -n openshift-operator-lifecycle-manager -o wide
oc get events -n openshift-operator-lifecycle-manager --sort-by=.lastTimestamp | tail -n 120
ss -ltnp | grep -E ':(6443|9080|9443)\b' || true
curl -skI https://127.0.0.1:6443/readyz || true
curl -sI http://127.0.0.1:9080 || true
curl -skI https://127.0.0.1:9443 || true
```

Healthy baseline:

- `oc whoami` succeeds
- node is `Ready`
- OLM (`catalog-operator`, `olm-operator`) is running
- host listeners exist on `6443`, `9080`, and `9443`

## 6. Local PVC Provisioning (Single-Node MINC)

Fresh local MINC clusters often have no default dynamic `StorageClass`. In that case, Kafka and Flink StatefulSet PVCs stay `Pending` unless you provision PVs.

Recommended path:

```bash
cd docs/microshift
scripts/provision-local-pv.sh --kafka-namespace kafka-dev --flink-namespace flink-dev
```

Kafka-only example:

```bash
cd docs/microshift
scripts/provision-local-pv.sh --kafka-only --kafka-namespace kafka-dev --kafka-replicas 3 --kafka-size 50Gi
```

Validate binding:

```bash
oc get pv
oc get pvc -n kafka-dev
oc get pvc -n flink-dev
```

## 7. DNS Diagnostics Sequence

```bash
ls -l /etc/resolv.conf
sed -n '1,80p' /etc/resolv.conf
sed -n '1,80p' /run/systemd/resolve/resolv.conf
sudo podman run --rm docker.io/library/alpine:3.20 cat /etc/resolv.conf
sudo podman run --rm docker.io/library/busybox:1.36 sh -c 'nslookup quay.io 1.1.1.1; echo ---; nslookup quay.io 8.8.8.8; echo ---; wget -T 10 -O- http://1.1.1.1 2>&1 | sed -n "1,20p"'
oc get events -n openshift-operator-lifecycle-manager --sort-by=.lastTimestamp | tail -n 120
```

## 8. Rebuild And Cleanup

Standard rebuild:

```bash
minc delete
minc create
```

Clean cluster delete:

```bash
minc status || true
minc list || true
minc delete
minc status || true
minc list || true
sudo podman ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}'
ss -ltnp | grep -E ':(6443|9080|9443)\b' || true
grep -n "microshift" "$HOME/.kube/config" || true
```

Podman network reset (higher impact):

```bash
minc delete || true
sudo podman rm -f microshift 2>/dev/null || true
sudo podman network rm podman 2>/dev/null || true
sudo podman network create podman
sudo podman network inspect podman
```

## Troubleshooting Map

Symptom: `minc create` succeeds but OLM is in `ImagePullBackOff`.

- Verify Podman DNS resolver and egress first.
- On Docker coexistence hosts, verify `DOCKER-USER` policy permits `podman0` forwarding.

Symptom: Docker works but Podman has no internet egress.

- Inspect `nftables` and `iptables` forwarding rules.
- Re-apply forwarding service and recreate cluster.

Symptom: `minc create --allow-rootless` fails.

- Set rootless through MINC config (`minc config set allow-rootless true`) and use `minc create`.

Symptom: Kafka/Flink pods stay `Pending` with events showing `pod has unbound immediate PersistentVolumeClaims`.

- Run `docs/microshift/scripts/provision-local-pv.sh` for the target namespaces.
- Re-check with `oc get pvc -n <namespace>` and then `oc get pods -n <namespace>`.

## Operational Recommendation

For the lowest-risk local setup, prefer Podman + MINC without Docker running.

If Docker must remain active, treat forwarding exceptions as mandatory platform configuration, not a one-off workaround.

## Handoff To Flink Namespace Setup

Once this local platform baseline is healthy, continue with Flink environment namespace and service identity setup:

- `../flink/openshift/namespaces-and-service-identities.md`
