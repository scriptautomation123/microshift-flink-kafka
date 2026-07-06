# NodePort External Access

This mode exposes each Kafka broker through a dedicated `NodePort` Service.

## Service Mapping

- `kafka-external-0` -> broker 0
- `kafka-external-1` -> broker 1
- `kafka-external-2` -> broker 2

## How It Works

- Each broker pod is selected by `statefulset.kubernetes.io/pod-name`.
- Each Service exposes the Envoy port from that broker pod.
- External clients connect using `node-ip:nodePort`.

## Typical Use

Use this mode when you have on-prem OpenShift and you do not have a load balancer or VIP layer available.
