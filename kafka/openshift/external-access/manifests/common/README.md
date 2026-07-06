# Common Manifests

These manifests are shared by both the NodePort and LoadBalancer external-access modes.

## Files

- `00-serviceaccount.yaml`: dedicated service account for the overlay.
- `01-headless-service.yaml`: internal broker identity and quorum service.
- `02-client-service.yaml`: in-cluster Kafka bootstrap service.
- `03-statefulset.yaml`: Kafka StatefulSet with Envoy sidecar support.
- `04-pdb.yaml`: disruption guardrail.
- `05-envoy-bootstrap.yaml`: Envoy bootstrap configuration.

## Notes

- The Kafka container advertises both internal and external listeners.
- The Envoy sidecar forwards TCP to the local broker endpoint.
- External services are added separately in the mode-specific folders.
