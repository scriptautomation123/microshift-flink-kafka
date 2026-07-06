# External Access Manifests

This directory contains the additive Kafka external-access overlay.

## Layout

- `common/`: shared Kafka StatefulSet, headless service, client service, PDB, and Envoy bootstrap config.
- `nodeport/`: per-broker `NodePort` Services.
- `loadbalancer/`: per-broker `LoadBalancer` Services.

## Design Rules

- Do not modify the existing Kafka bundle.
- Keep broker-to-endpoint mapping consistent across modes.
- Use one external Service per broker pod.
- Preserve the existing headless service for internal broker identity.
- Keep the client service available for in-cluster bootstrap traffic.

## Deployment Order

1. Apply the common manifests.
2. Apply the mode-specific service manifests.
3. Validate that each broker has a stable external address.
