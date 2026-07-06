# LoadBalancer External Access

This mode exposes each Kafka broker through a dedicated `LoadBalancer` Service.

## Service Mapping

- `kafka-external-0` -> broker 0
- `kafka-external-1` -> broker 1
- `kafka-external-2` -> broker 2

## How It Works

- Each broker pod is selected by `statefulset.kubernetes.io/pod-name`.
- Each Service exposes the Envoy port from that broker pod.
- External clients connect using the broker VIP or DNS name assigned by the load balancer.

## Typical Use

Use this mode when MetalLB, a VIP, or an enterprise load balancer is available and you want stable external addresses per broker.
