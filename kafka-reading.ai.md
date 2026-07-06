# Kafka HA on Kubernetes (AI-Optimized Reference)

## Document Metadata
- title: Designing and Testing a Highly Available Kafka Cluster on Kubernetes
- source_type: article notes export
- source_date: 2022-04
- primary_topic: Kafka high availability with Kubernetes StatefulSet
- scope: architecture, deployment, failure testing, recovery patterns
- audience: platform engineers, SRE, data platform teams
- parsing_profile: structured_markdown_v1

## Executive Summary
This document describes how to design and validate a Kafka cluster on Kubernetes for high availability.

Core design choices:
- Prefer availability over strict consistency during certain failures.
- Use simple Kubernetes primitives for clarity.
- Assume node maintenance and disruptions are common.

Target HA baseline:
- replication.factor = 3
- min.insync.replicas = 2
- 3 brokers on separate nodes
- spread brokers across zones/failure domains

Outcome:
- Cluster remains available for producer/consumer traffic during single-broker outages.
- Cluster becomes unavailable for acknowledged writes when only one ISR remains.
- PodDisruptionBudget prevents voluntary operations that would drop availability below quorum.

## Canonical Concepts

### Kafka Replication Concepts
- Topic: logical stream of records.
- Partition: ordered shard of topic data.
- Leader: replica serving reads/writes for a partition.
- Follower: replica syncing from leader.
- ISR (in-sync replicas): replicas caught up enough to be eligible for leader election.

### Kubernetes Concepts Used
- StatefulSet: stable pod identity and storage mapping.
- Headless Service (clusterIP: None): DNS returns individual pod endpoints.
- PersistentVolumeClaim/PersistentVolume: per-broker durable storage.
- Topology spread constraints: distribute pods across failure domains.
- PodDisruptionBudget: limit voluntary disruptions.

## Key Design Requirements
1. Keep min.insync.replicas at 2.
2. Keep topic replication factor at 3.
3. Run at least 3 brokers.
4. Place brokers on different nodes.
5. Prefer zone-level spread when possible.

## Reference Kubernetes Manifest Pattern

### Headless Service
Purpose:
- Provide stable DNS for each StatefulSet pod.

Core settings:
- kind: Service
- spec.clusterIP: None
- port: 9092
- selector: app=kafka-app

### StatefulSet
Purpose:
- Run 3 brokers with stable names and per-pod persistent storage.

Core settings:
- kind: StatefulSet
- metadata.name: kafka
- spec.replicas: 3
- spec.serviceName: kafka-svc
- pod names: kafka-0, kafka-1, kafka-2

Important container env vars:
- REPLICAS=3
- SERVICE=kafka-svc
- NAMESPACE=default
- SHARE_DIR=/mnt/kafka
- CLUSTER_ID=<unique-id>
- DEFAULT_REPLICATION_FACTOR=3
- DEFAULT_MIN_INSYNC_REPLICAS=2

Storage:
- volumeClaimTemplates per broker
- accessModes: ReadWriteOnce
- requested storage: 1Gi
- mountPath: /mnt/kafka

## DNS and Addressability Model
With StatefulSet + headless service, each broker has a predictable FQDN:

- kafka-0.kafka-svc.default.svc.cluster.local
- kafka-1.kafka-svc.default.svc.cluster.local
- kafka-2.kafka-svc.default.svc.cluster.local

This enables deterministic broker discovery and stable identity in scripts and configs.

## Validation Workflow

### 1) Deploy Cluster
Expected result:
- Service created
- StatefulSet ready with 3/3 brokers
- One PVC per broker

### 2) Produce and Consume Test Message
Test topic: test

Producer behavior:
- Use request-required-acks=all for stronger durability semantics.

Consumer behavior:
- Read from beginning and verify messages appear.

Expected output example:
- hello world

### 3) Inspect Topic State
Use topic describe and verify:
- PartitionCount=1
- ReplicationFactor=3
- min.insync.replicas=2
- Leader is one broker
- ISR includes all 3 when healthy

## Failure and Recovery Scenarios

### Scenario A: Planned maintenance on leader node (single-node drain)
Action:
- Drain node hosting leader broker.

Observed behavior:
- Leader changes to another in-sync replica.
- Producer and consumer continue to work.
- Evicted broker pod may remain Pending if PV is node-affined to drained node.
- ISR temporarily reduces (for example from 3 to 2).

Why Pending can happen:
- Local-path provisioner may enforce PV nodeAffinity.
- Broker cannot mount its volume on another node.

### Scenario B: Node returns after maintenance
Action:
- Uncordon drained node.

Observed behavior:
- Broker pod schedules back to node owning its PV.
- Broker catches up and re-enters ISR.
- Cluster returns to full strength (ISR includes all brokers).

### Scenario C: Two nodes drained (voluntary disruption beyond quorum)
Action:
- Drain second node while first broker already unavailable.

Observed behavior:
- Only one broker remains running.
- Producer with acks=all fails with NOT_ENOUGH_REPLICAS.
- Cluster effectively unavailable for quorum-protected writes.

### Scenario D: Protect against unsafe voluntary evictions
Mitigation:
- Add PodDisruptionBudget with minAvailable: 2 for kafka pods.

Observed behavior:
- Drain that would reduce available brokers below 2 is blocked.
- Node may still be cordoned, but protected pod eviction is denied.

### Scenario E: Permanent node loss (unplanned)
Action:
- Delete dead node object.

Observed behavior:
- Broker tied to lost node's local PV remains Pending.
- Cluster can still function with 2 brokers if ISR satisfies min.insync.replicas.
- Voluntary maintenance flexibility is reduced until replacement is complete.

Recovery path:
1. Add replacement worker in same zone/failure domain objective.
2. Delete affected PVC tied to lost storage.
3. Delete pending broker pod.
4. StatefulSet recreates broker + new PVC/PV.
5. Wait for replica sync and ISR convergence.

## PodDisruptionBudget Reference
Intent:
- Preserve quorum during voluntary disruptions.

Minimal policy shape:
- apiVersion: policy/v1
- kind: PodDisruptionBudget
- spec.minAvailable: 2
- selector: app=kafka-app

## Operational Invariants
- Do not run production RF=3 topics on fewer than 3 healthy broker identities for long periods.
- Keep ISR count at or above min.insync.replicas for write availability with acks=all.
- Expect leader re-election on broker failure.
- Expect local-path PV node affinity to constrain rescheduling.
- Protect planned maintenance with PDB.

## Practical Command Catalog

### Cluster and Resource Inspection
- kubectl get nodes
- kubectl get pods -l app=kafka-app
- kubectl describe service kafka-svc
- kubectl get pvc,pv
- kubectl describe pod kafka-1

### Topic and Broker Inspection (from client pod)
- kafka-topics.sh --describe --topic test --bootstrap-server <brokers>
- kafka-console-producer.sh --topic test --request-required-acks all --bootstrap-server <brokers>
- kafka-console-consumer.sh --topic test --from-beginning --bootstrap-server <brokers>

### Maintenance Operations
- kubectl drain <node> --delete-emptydir-data --force --ignore-daemonsets
- kubectl uncordon <node>

### Failure Recovery Operations
- kubectl delete node <dead-node>
- kubectl delete pvc data-kafka-<ordinal>
- kubectl delete pod kafka-<ordinal>

## Decision Matrix

| Condition | Expected Kafka State | Producer with acks=all | Consumer Readability | Operator Action |
|---|---|---|---|---|
| 3 brokers healthy, ISR=3 | Healthy | Success | Success | Normal ops |
| 1 broker down, ISR=2 | Degraded but available | Success | Success | Restore node or verify catch-up |
| 2 brokers down, ISR=1 | Quorum lost | Fails (NOT_ENOUGH_REPLICAS) | Degraded/blocked behavior likely | Recover at least one broker |
| Voluntary drain would violate PDB | Protected state | N/A | N/A | Drain blocked; re-plan maintenance |
| Permanent node loss with local PV | Partial capacity | Usually works if ISR>=2 | Usually works | Replace node/broker and resync |

## Known Constraints and Caveats
- This walkthrough uses Kafka KRaft mode for simplicity.
- Original source notes claim KRaft limitations at that time (2022 context).
- Production readiness and feature completeness should be validated against current Kafka version and vendor guidance.
- Storage behavior depends on provisioner; local-path specifics are not universal.

## AI Extraction Blocks

### Structured Facts (YAML)
```yaml
cluster:
  brokers: 3
  statefulset_name: kafka
  service_name: kafka-svc
  ports:
    client: 9092
    inter_broker: 9093
kafka_defaults:
  replication_factor: 3
  min_insync_replicas: 2
storage:
  mode: per-broker PVC
  access_mode: ReadWriteOnce
  size: 1Gi
ha_controls:
  topology_spread: true
  pod_disruption_budget:
    min_available: 2
failure_tolerance:
  single_broker_loss: tolerated
  double_broker_loss: not tolerated_for_acks_all_writes
```

### Runbook Checklist
- Confirm 3 brokers running.
- Confirm topic RF=3 and min.insync.replicas=2.
- Confirm ISR includes all brokers during steady state.
- Before maintenance, verify PDB exists and is effective.
- Drain one node at a time.
- After maintenance, uncordon and confirm broker rejoins ISR.
- If permanent node loss, replace node and rebuild missing broker identity/storage.

## Suggested Tags
- kafka
- kubernetes
- statefulset
- headless-service
- pod-disruption-budget
- topology-spread
- high-availability
- kraft
