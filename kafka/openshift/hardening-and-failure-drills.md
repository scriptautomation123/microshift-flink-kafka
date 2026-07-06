# Kafka KRaft Hardening And Failure Drills On OpenShift

This runbook mirrors the Learnkube high-availability exercise with OpenShift commands and namespace-scoped Kafka resources.

Use this with the package at [README.md](README.md).

## Objectives

1. Validate that the cluster continues serving produce/consume operations during single-broker disruption.
2. Verify PodDisruptionBudget behavior during voluntary disruptions.
3. Practice broker recovery when a node is permanently lost.
4. Verify ISR convergence after recovery.

## Preconditions

1. Kafka deployed from this package and healthy:

```bash
cd /home/swapanc/Documents/swapan-info
export PATH="$HOME/.local/bin:$PATH"
docs/kafka/openshift/scripts/check.sh docs/kafka/openshift/env/dev.env
```

2. At least 3 schedulable worker nodes for meaningful topology behavior.

3. You can run drain/cordon operations (`oc adm`) on the target cluster.

4. Optional but recommended: run the non-destructive guard helper before and after each maintenance action.

```bash
docs/kafka/openshift/scripts/maintenance-guard.sh docs/kafka/openshift/env/dev.env --topic ha-drill --phase pre
```

## 1. Baseline Hardening Controls

Use these controls before failure drills.

1. Replication and ISR defaults

- `default.replication.factor=3`
- `min.insync.replicas=2`

These are configured in [03-statefulset.yaml](manifests/03-statefulset.yaml) and rendered by [render-manifests.sh](scripts/render-manifests.sh).

2. Pod disruption guardrail

- `minAvailable: 2` in [04-pdb.yaml](manifests/04-pdb.yaml)

3. Topology spread and anti-affinity

- enabled in [03-statefulset.yaml](manifests/03-statefulset.yaml) for improved broker spreading.

4. Rootless runtime image

- [Dockerfile.kraft](images/Dockerfile.kraft)
- [start-kafka-kraft.sh](images/bin/start-kafka-kraft.sh)

## 2. Create A Drill Topic

Create the drill topic with the CI/CD-safe Job helper and then describe it over a port-forward.

```bash
kafka/openshift/scripts/create-topic.sh kafka/openshift/env/dev.env \
  --topic ha-drill \
  --partitions 3 \
  --replication-factor 3 \
  --min-insync 2
```

Describe the topic baseline:

```bash
export NS=kafka-dev
oc port-forward -n "$NS" svc/kafka 9092:9092 &
kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic ha-drill
```

Expected shape:

- each partition has 3 replicas
- ISR contains 3 broker ids in healthy state

## 3. Produce And Consume Baseline Data

Produce test events:

```bash
oc exec -n "$NS" kafka-0 -- bash -lc '
for i in $(seq 1 20); do
  echo "baseline-${i}"
done | /opt/kafka/bin/kafka-console-producer.sh \
  --topic ha-drill \
  --request-required-acks all \
  --bootstrap-server kafka.'"$NS"'.svc:9092
'
```

Consume from beginning to verify:

```bash
oc exec -n "$NS" kafka-1 -- /opt/kafka/bin/kafka-console-consumer.sh \
  --topic ha-drill \
  --from-beginning \
  --timeout-ms 10000 \
  --bootstrap-server kafka.${NS}.svc:9092
```

## 4. Identify Leader And Hosting Node

Describe topic and choose one partition leader to target:

```bash
oc exec -n "$NS" kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --describe \
  --topic ha-drill \
  --bootstrap-server kafka.${NS}.svc:9092
```

Map leader broker id to pod and node:

```bash
oc get pod -n "$NS" -o wide -l app.kubernetes.io/name=kafka
```

If leader is broker `1`, target pod is `kafka-1`.

## 5. Drill A: Single Node Drain Hosting Leader

Cordon and drain node hosting that leader pod:

```bash
export NODE=<node-hosting-leader-pod>
oc adm cordon "$NODE"
oc adm drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force
```

Observe pod status:

```bash
oc get pod -n "$NS" -o wide -l app.kubernetes.io/name=kafka -w
```

Re-check topic leader/ISR:

```bash
oc exec -n "$NS" kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --describe \
  --topic ha-drill \
  --bootstrap-server kafka.${NS}.svc:9092
```

Expected outcome:

1. leader migrates to another ISR member
2. cluster keeps producing/consuming with one broker unavailable
3. ISR temporarily drops to 2 for affected partitions

Validate produce/consume during disruption:

```bash
oc exec -n "$NS" kafka-2 -- bash -lc '
echo "during-drain" | /opt/kafka/bin/kafka-console-producer.sh \
  --topic ha-drill \
  --request-required-acks all \
  --bootstrap-server kafka.'"$NS"'.svc:9092
'

oc exec -n "$NS" kafka-2 -- /opt/kafka/bin/kafka-console-consumer.sh \
  --topic ha-drill \
  --from-beginning \
  --timeout-ms 10000 \
  --bootstrap-server kafka.${NS}.svc:9092
```

Uncordon after maintenance:

```bash
oc adm uncordon "$NODE"
```

Post-maintenance assertion run:

```bash
docs/kafka/openshift/scripts/maintenance-guard.sh docs/kafka/openshift/env/dev.env --topic ha-drill --phase post
```

## 6. Drill B: Verify PDB Blocks Unsafe Second Drain

With one broker still unavailable (or while running with 2 healthy), attempt draining a second node hosting another broker.

```bash
export NODE2=<another-kafka-node>
oc adm cordon "$NODE2"
oc adm drain "$NODE2" --ignore-daemonsets --delete-emptydir-data --force
```

Expected behavior:

- drain should fail to evict a Kafka pod due to PDB (`minAvailable: 2`)
- this prevents dropping Kafka below quorum-safe serving posture

Inspect PDB status:

```bash
oc get pdb -n "$NS"
oc describe pdb kafka -n "$NS"
```

## 7. Drill C: Permanent Node Loss And Broker Replacement

This mirrors the "node not coming back" scenario.

1. Remove failed node from cluster inventory (platform step; may be automatic).
2. Identify stuck broker pod (`Pending`) and its PVC:

```bash
oc get pod -n "$NS" -o wide -l app.kubernetes.io/name=kafka
oc get pvc -n "$NS" -l app.kubernetes.io/name=kafka
```

3. If storage is node-local and unrecoverable, delete the failed broker PVC to allow a fresh broker volume:

```bash
export FAILED_ORDINAL=2
oc delete pvc -n "$NS" data-kafka-${FAILED_ORDINAL}
```

4. Delete the stuck pod so StatefulSet recreates it:

```bash
oc delete pod -n "$NS" kafka-${FAILED_ORDINAL}
```

5. Watch replacement bootstrap:

```bash
oc get pod -n "$NS" -w -l app.kubernetes.io/name=kafka
```

6. Verify ISR convergence after catch-up:

```bash
oc exec -n "$NS" kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --describe \
  --topic ha-drill \
  --bootstrap-server kafka.${NS}.svc:9092
```

Expected outcome:

- replacement broker rejoins
- ISR returns to full set for healthy partitions

## 8. SLO-Focused Acceptance Criteria

Treat the drill as passed when:

1. Single-broker disruption does not block produce/consume with `acks=all` and `min.insync.replicas=2`.
2. PDB prevents unsafe second voluntary eviction.
3. Replacement broker can rejoin and ISR reconverges.
4. No unclean leader election is observed.

## 9. Day-2 Hardening Recommendations

1. Keep partition replication factor aligned with broker count and fault domains.
2. Keep `min.insync.replicas` at 2 for 3-broker clusters.
3. Avoid running all brokers on the same node/failure domain.
4. Perform controlled drain drills quarterly.
5. Keep a documented broker replacement path for your storage class behavior.

## 10. Related Docs And Assets

- Package entry: [README.md](README.md)
- StatefulSet spec: [03-statefulset.yaml](manifests/03-statefulset.yaml)
- PDB: [04-pdb.yaml](manifests/04-pdb.yaml)
- Deploy script: [deploy.sh](scripts/deploy.sh)
- Check script: [check.sh](scripts/check.sh)
- Maintenance helper: [maintenance-guard.sh](scripts/maintenance-guard.sh)
- Delete script: [delete.sh](scripts/delete.sh)
- Manifest renderer: [render-manifests.sh](scripts/render-manifests.sh)
