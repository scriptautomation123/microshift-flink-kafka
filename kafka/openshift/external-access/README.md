# Kafka External Access Overlay

This bundle is a companion overlay for the existing Kafka KRaft deployment. It does not modify the current Kafka bundle.

Use this bundle when you need external Java clients to connect to Kafka from outside OpenShift while keeping the existing Kafka runtime files untouched.

## What This Bundle Provides

- A copied Kafka StatefulSet with an Envoy sidecar per broker pod.
- Per-broker external Services.
- Separate external-access modes for `NodePort` and `LoadBalancer`.
- Render and deploy scripts that operate only on this overlay.
- Documentation for the external listener model, bootstrap flow, and broker identity.

## Supported External Patterns

### 1. NodePort

- Each broker gets its own `NodePort` Service.
- External clients connect to `node-ip:node-port`.
- Kafka advertises stable external broker hostnames and ports.
- Best for bare-metal or on-prem OpenShift when a load balancer is not available.
- Uses the same broker order as the LoadBalancer mode: broker 0, broker 1, broker 2.

### 2. LoadBalancer

- Each broker gets its own `LoadBalancer` Service.
- External clients connect to a stable external VIP or hostname.
- Kafka advertises broker-specific external hostnames and ports.
- Best when MetalLB, an enterprise VIP, or a cloud provider LB exists.
- Uses the same broker order as the NodePort mode: broker 0, broker 1, broker 2.

### 3. Envoy per broker

- A TCP Envoy sidecar runs in every broker pod.
- Each broker is exposed by its own external Service.
- Envoy forwards traffic to the local broker process inside the same pod.
- Kafka still advertises broker-specific external addresses.

## Layout

- `env/example.env`: sample external-access settings
- `manifests/common/`: shared Kafka and Envoy manifests for the overlay
- `manifests/nodeport/`: per-broker external services for NodePort mode
- `manifests/loadbalancer/`: per-broker external services for LoadBalancer mode
- `scripts/render.sh`: renders the overlay into `.rendered/`
- `scripts/deploy.sh`: applies the rendered overlay
- `scripts/check.sh`: validates the rendered overlay and prints bootstrap endpoints

## Prerequisites

1. The base Kafka namespace already exists.
2. The Kafka pods are deployed from the existing Kafka bundle or an equivalent StatefulSet.
3. DNS or external routing is available for the broker hostnames you choose to advertise.
4. Kafka CLI tools are available for testing external connectivity.

## Important Design Note

This overlay keeps the current Kafka bundle untouched. The external listener behavior is implemented in the copied StatefulSet under this folder, not by editing the original files.

Because Kafka clients read broker metadata after bootstrap, each broker must have a stable external address. This bundle therefore uses one external Service per broker and one Envoy sidecar per broker pod.

## Usage

```bash
cd kafka/openshift/external-access
cp env/example.env env/dev.env
# edit env/dev.env

scripts/render.sh env/dev.env
scripts/deploy.sh env/dev.env
scripts/check.sh env/dev.env
```

## Validation Flow

1. Render the overlay.
2. Apply the shared manifests.
3. Apply the mode-specific external Services.
4. Wait for Kafka and Envoy to become ready.
5. Connect an external Java client to the advertised broker endpoints.

## External Client Bootstrap Example

```properties
bootstrap.servers=broker-0.example.com:31092,broker-1.example.com:31093,broker-2.example.com:31094
security.protocol=PLAINTEXT
```

## Principle

- Internal traffic stays on the existing headless and client Services.
- External traffic is isolated in this overlay.
- NodePort and LoadBalancer are documented separately so the transport choice is explicit.
